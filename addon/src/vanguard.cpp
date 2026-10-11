// SPDX-License-Identifier: LGPL-3.0-or-later
// fcitx5-vanguard：把引擎（Swift，經 vanguard.h 的 C 介面）接到 fcitx5 的薄殼。
#include <cstdlib>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <fcitx-utils/event.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>
#include <fcitx/text.h>
#include <fcitx/userinterface.h>

#include "vanguard.h"

namespace {

FCITX_DEFINE_LOG_CATEGORY(vanguard_log, "vanguard");
#define VANGUARD_INFO() FCITX_LOGC(vanguard_log, Info)
#define VANGUARD_DEBUG() FCITX_LOGC(vanguard_log, Debug)
#define VANGUARD_ERROR() FCITX_LOGC(vanguard_log, Error)

// 閒置時排空引擎主佇列的間隔。背景執行緒等主佇列時，最久會等這麼久。
constexpr uint64_t kPumpIntervalUsec = 50000;

// 引擎回傳的 C 字串要用 vg_free() 釋放。
std::string takeString(char *raw) {
    std::string result = raw ? raw : "";
    vg_free(raw);
    return result;
}

class VanguardEngine;

class VanguardCandidateWord final : public fcitx::CandidateWord {
public:
    VanguardCandidateWord(VanguardEngine *engine, std::string text, int index)
        : fcitx::CandidateWord(fcitx::Text(std::move(text))), engine_(engine), index_(index) {}

    void select(fcitx::InputContext *inputContext) const override;

private:
    VanguardEngine *engine_;
    int index_;
};

class VanguardEngine final : public fcitx::InputMethodEngineV2 {
public:
    explicit VanguardEngine(fcitx::Instance *instance) : instance_(instance) {
        const char *fromEnv = std::getenv("FCITX5_VANGUARD_TEXTMAP");
        const std::string textMap = (fromEnv && *fromEnv) ? fromEnv : VANGUARD_DEFAULT_TEXTMAP;
        // 使用者語彙與選字記憶放在 fcitx5 的使用者資料目錄底下（通常是 ~/.local/share/fcitx5/vanguard）。
        const std::string userData =
            fcitx::StandardPath::global().userDirectory(fcitx::StandardPath::Type::PkgData) + "/vanguard";
        const int32_t rc =
            vg_init(textMap.c_str(), userData.c_str(), this, &VanguardEngine::onCommit, &VanguardEngine::onUpdate);
        if (rc != 0) {
            VANGUARD_ERROR() << "vg_init failed, rc=" << rc << ", textmap=" << textMap << ", userdata=" << userData;
            return;
        }
        ready_ = true;
        VANGUARD_INFO() << "engine started, textmap=" << textMap << ", userdata=" << userData;
        pump();

        // 引擎有工作排在 libdispatch 主佇列上，而 fcitx5 不跑 dispatch 主迴圈。
        // 每次呼叫引擎之後會排空一次；這個定時器負責閒置期間。
        pumpTimer_ = instance_->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + kPumpIntervalUsec, 0,
            [this](fcitx::EventSourceTime *timer, uint64_t) {
                pump();
                timer->setNextInterval(kPumpIntervalUsec);
                timer->setOneShot();
                return true;
            });
    }

    ~VanguardEngine() override {
        if (!ready_) return;
        pumpTimer_.reset();
        // 把選字記憶與偏好設定寫回磁碟。
        vg_shutdown();
        vg_pump();
    }

    void activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        VANGUARD_DEBUG() << __func__;
        if (!ready_) return;
        inputContext_ = event.inputContext()->watch();
        vg_focus_in();
        pump();
    }

    void deactivate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        VANGUARD_DEBUG() << __func__;
        if (!ready_) return;
        inputContext_ = event.inputContext()->watch();
        // 切換輸入法時由我們把組字區的字送出去。焦點離開時 fcitx5 會自己送出客體端的組字區，
        // 這裡再送一次會變成重複送字，所以只清掉。
        const bool switching = event.type() == fcitx::EventType::InputContextSwitchInputMethod;
        vg_reset(switching ? 1 : 0);
        dirty_ = true;
        pump();
        inputContext_.unwatch();
    }

    void reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) override {
        VANGUARD_DEBUG() << __func__;
        if (!ready_) return;
        inputContext_ = event.inputContext()->watch();
        vg_reset(0);
        dirty_ = true;
        pump();
    }

    void keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &keyEvent) override {
        // 放開的事件與單獨的修飾鍵不送進引擎。
        if (!ready_ || keyEvent.isRelease() || keyEvent.key().isModifier()) return;
        inputContext_ = keyEvent.inputContext()->watch();

        const fcitx::Key key = keyEvent.rawKey();
        // 上游的鍵碼轉換把 Num Lock 當成「這是數字鍵盤的鍵」，開著 Num Lock 時所有按鍵都會被誤判，
        // 所以這個位元不送進引擎。
        const auto states = key.states().unset(fcitx::KeyState::NumLock);
        const int32_t handled = vg_key_down(static_cast<uint32_t>(key.sym()), static_cast<uint32_t>(states));
        pump();
        if (handled) keyEvent.filterAndAccept();
    }

    void selectCandidate(fcitx::InputContext *inputContext, int index) {
        inputContext_ = inputContext->watch();
        vg_candidate_select(index);
        pump();
    }

private:
    static void onCommit(void *context, const char *text) {
        auto *self = static_cast<VanguardEngine *>(context);
        VANGUARD_DEBUG() << "commit: " << text;
        if (auto *inputContext = self->inputContext_.get()) inputContext->commitString(text);
    }

    // 一次按鍵可能觸發很多次更新，這裡只記下來，等 pump() 結束時一起畫。
    static void onUpdate(void *context) { static_cast<VanguardEngine *>(context)->dirty_ = true; }

    void pump() {
        vg_pump();
        if (!lexiconReported_) {
            // 辭庫是非同步載入的，好了（或失敗）之後記一筆，方便從紀錄看出啟動花了多久。
            const int32_t state = vg_lexicon_state();
            if (state != 0) {
                lexiconReported_ = true;
                if (state > 0) {
                    VANGUARD_INFO() << "lexicon loaded";
                } else {
                    VANGUARD_ERROR() << "lexicon failed to load";
                }
            }
        }
        if (!dirty_) return;
        dirty_ = false;
        if (auto *inputContext = inputContext_.get()) updateUI(inputContext);
    }

    void updateUI(fcitx::InputContext *inputContext) {
        auto &panel = inputContext->inputPanel();
        panel.reset();

        const std::string preedit = takeString(vg_preedit());
        if (!preedit.empty()) {
            const bool clientPreedit = inputContext->capabilityFlags().test(fcitx::CapabilityFlag::Preedit);
            fcitx::Text text(preedit, clientPreedit ? fcitx::TextFormatFlag::Underline : fcitx::TextFormatFlag::NoFlag);
            text.setCursor(vg_preedit_cursor());
            if (clientPreedit) {
                panel.setClientPreedit(text);
            } else {
                panel.setPreedit(text);
            }
        }

        // 引擎自己分頁，這裡只把目前這一頁交給 fcitx5 畫。
        const int32_t count = vg_candidates_visible() ? vg_candidate_count() : 0;
        if (count > 0) {
            auto list = std::make_unique<fcitx::CommonCandidateList>();
            list->setLayoutHint(fcitx::CandidateLayoutHint::Horizontal);
            list->setPageSize(count);
            std::vector<std::string> labels;
            for (int32_t i = 0; i < count; i++) {
                labels.push_back(takeString(vg_candidate_label(i)) + ". ");
                list->append<VanguardCandidateWord>(this, takeString(vg_candidate_text(i)), i);
            }
            list->setLabels(labels);
            const int32_t highlighted = vg_candidate_highlighted();
            if (highlighted >= 0) list->setGlobalCursorIndex(highlighted);
            panel.setCandidateList(std::move(list));
        }

        inputContext->updatePreedit();
        inputContext->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    fcitx::Instance *instance_;
    bool ready_ = false;
    bool dirty_ = false;
    bool lexiconReported_ = false;
    // 引擎目前在服務的輸入情境。第一版所有情境共用一個引擎 session。
    fcitx::TrackableObjectReference<fcitx::InputContext> inputContext_;
    std::unique_ptr<fcitx::EventSourceTime> pumpTimer_;
};

void VanguardCandidateWord::select(fcitx::InputContext *inputContext) const {
    engine_->selectCandidate(inputContext, index_);
}

class VanguardEngineFactory final : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new VanguardEngine(manager->instance());
    }
};

} // namespace

FCITX_ADDON_FACTORY(VanguardEngineFactory)

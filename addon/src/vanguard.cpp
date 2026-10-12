// SPDX-License-Identifier: LGPL-3.0-or-later
// fcitx5-vanguard：把引擎（Swift，經 vanguard.h 的 C 介面）接到 fcitx5 的薄殼。
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx-utils/utf8.h>
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
// 單獨按一下 Shift 切換英數：按下到放開不超過這麼久、中間沒有按別的鍵才算。
constexpr uint64_t kShiftTapMaxUsec = 500000;

// 引擎回傳的 C 字串要用 vg_free() 釋放。
std::string takeString(char *raw) {
    std::string result = raw ? raw : "";
    vg_free(raw);
    return result;
}

// fcitx5 設定介面裡看得到的選項。值存在引擎自己的偏好設定裡（見 vg_pref_get／vg_pref_set），
// 這裡只是把其中幾項搬到設定視窗上，不另外存檔。
FCITX_CONFIGURATION(
    VanguardConfig,
    fcitx::Option<bool> horizontalCandidates{this, "HorizontalCandidateList", "選字視窗橫排（關掉就是直排）", true};
    fcitx::Option<std::string> candidateKeys{this, "CandidateKeys",
                                             "選字鍵（有幾個字元，一頁就有幾個候選字，例如 123456789）", "123456"};
    fcitx::Option<bool> mixedAlnum{this, "MixedAlphanumerical",
                                   "中英混打：不用切換，按鍵不成注音時自動當成英文（Shift+空白鍵可強制送出英文）", false};
    fcitx::Option<bool> shiftLeft{this, "ToggleWithLeftShift", "單獨按一下左 Shift 切換中英", true};
    fcitx::Option<bool> shiftRight{this, "ToggleWithRightShift", "單獨按一下右 Shift 切換中英", true};
    fcitx::Option<bool> shiftNotice{this, "ShowNoticeWhenToggling", "切換中英時顯示提示", true};);

// 給獨立設定程式（settings/）用的通道，掛在 fcitx://config/addon/vanguard/prefs。
// 讀：Json 是引擎全部偏好設定的清單（vg_pref_describe 的輸出），Errors 是上一次寫入被拒絕的項目。
// 寫：送來的每一組「key = 值」直接交給 vg_pref_set；key 用引擎的 UserDef 名稱。
// 這條通道不會出現在 fcitx5 自己的設定視窗裡。
FCITX_CONFIGURATION(
    VanguardPrefsConfig,
    fcitx::Option<std::string> json{this, "Json", "All engine preferences as JSON", "[]"};
    fcitx::Option<std::string> errors{this, "Errors", "Keys rejected by the last write", ""};
    fcitx::Option<std::string> userDataDir{this, "UserDataDir", "Folder holding user phrases", ""};);

// 設定視窗的選項對應到引擎的哪個偏好設定。
constexpr const char *kPrefHorizontal = "UseHorizontalCandidateList";
constexpr const char *kPrefCandidateKeys = "CandidateKeys";
constexpr const char *kPrefMixedAlnum = "MixedAlphanumericalEnabled";
constexpr const char *kPrefShiftLeft = "TogglingAlphanumericalModeWithLShift";
constexpr const char *kPrefShiftRight = "TogglingAlphanumericalModeWithRShift";
constexpr const char *kPrefShiftNotice = "ShowNotificationsWhenTogglingShift";

class VanguardEngine;

// 單一個字就回傳「U+6A23」這種碼位標示；多個字或空字串回傳空字串。
std::string codePointLabel(const std::string &text) {
    if (text.empty() || fcitx::utf8::length(text) != 1) return {};
    const uint32_t codePoint = fcitx::utf8::getChar(text);
    char buffer[16];
    std::snprintf(buffer, sizeof(buffer), "U+%04X", codePoint);
    return buffer;
}

class VanguardCandidateWord final : public fcitx::CandidateWord {
public:
    VanguardCandidateWord(VanguardEngine *engine, std::string text, int index)
        : fcitx::CandidateWord(fcitx::Text(std::move(text))), engine_(engine), index_(index) {}

    void select(fcitx::InputContext *inputContext) const override;

private:
    VanguardEngine *engine_;
    int index_;
};

// 引擎自己分頁，這裡只拿到目前這一頁。翻頁狀態要另外告訴 fcitx5，選字視窗才會畫出翻頁箭頭；
// 使用者用滑鼠點箭頭時再轉回去請引擎翻頁。
class VanguardCandidateList final : public fcitx::CommonCandidateList {
public:
    VanguardCandidateList(VanguardEngine *engine, int page, int pages)
        : engine_(engine), page_(page), pages_(pages) {}

    bool hasPrev() const override { return page_ > 0; }
    bool hasNext() const override { return page_ + 1 < pages_; }
    void prev() override;
    void next() override;
    bool usedNextBefore() const override { return true; }
    int totalPages() const override { return pages_; }
    int currentPage() const override { return page_; }

private:
    VanguardEngine *engine_;
    int page_;
    int pages_;
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
        userDataDir_ = userData;
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
        if (!ready_) return;
        if (handleShiftTap(keyEvent)) return;
        // 放開的事件與單獨的修飾鍵不送進引擎。
        if (keyEvent.isRelease() || keyEvent.key().isModifier()) return;
        inputContext_ = keyEvent.inputContext()->watch();

        const fcitx::Key key = keyEvent.rawKey();
        // 上游的鍵碼轉換把 Num Lock 當成「這是數字鍵盤的鍵」，開著 Num Lock 時所有按鍵都會被誤判，
        // 所以這個位元不送進引擎。
        const auto states = key.states().unset(fcitx::KeyState::NumLock);
        const int32_t handled = vg_key_down(static_cast<uint32_t>(key.sym()), static_cast<uint32_t>(states));
        pump();
        if (handled) keyEvent.filterAndAccept();
    }

    // 設定視窗打開時 fcitx5 來要目前的值：每次都從引擎讀，引擎才是唯一的來源。
    const fcitx::Configuration *getConfig() const override {
        if (ready_) {
            config_.horizontalCandidates.setValue(prefBool(kPrefHorizontal));
            config_.candidateKeys.setValue(takeString(vg_pref_get(kPrefCandidateKeys)));
            config_.mixedAlnum.setValue(prefBool(kPrefMixedAlnum));
            config_.shiftLeft.setValue(prefBool(kPrefShiftLeft));
            config_.shiftRight.setValue(prefBool(kPrefShiftRight));
            config_.shiftNotice.setValue(prefBool(kPrefShiftNotice));
        }
        return &config_;
    }

    // 使用者在設定視窗按了套用：寫回引擎，引擎會立刻存檔並套用。
    void setConfig(const fcitx::RawConfig &raw) override {
        if (!ready_) return;
        config_.load(raw, true);
        vg_pref_set(kPrefHorizontal, *config_.horizontalCandidates ? "true" : "false");
        // 引擎會檢查選字鍵合不合法，不合法就回到預設值。
        vg_pref_set(kPrefCandidateKeys, config_.candidateKeys->c_str());
        vg_pref_set(kPrefMixedAlnum, *config_.mixedAlnum ? "true" : "false");
        vg_pref_set(kPrefShiftLeft, *config_.shiftLeft ? "true" : "false");
        vg_pref_set(kPrefShiftRight, *config_.shiftRight ? "true" : "false");
        vg_pref_set(kPrefShiftNotice, *config_.shiftNotice ? "true" : "false");
        dirty_ = true;
        pump();
    }

    const fcitx::Configuration *getSubConfig(const std::string &path) const override {
        if (path != "prefs" || !ready_) return nullptr;
        prefsConfig_.json.setValue(takeString(vg_pref_describe()));
        prefsConfig_.errors.setValue(prefErrors_);
        prefsConfig_.userDataDir.setValue(userDataDir_);
        return &prefsConfig_;
    }

    void setSubConfig(const std::string &path, const fcitx::RawConfig &raw) override {
        if (path != "prefs" || !ready_) return;
        prefErrors_.clear();
        for (const auto &key : raw.subItems()) {
            const auto item = raw.get(key);
            if (!item) continue;
            const int32_t rc = vg_pref_set(key.c_str(), item->value().c_str());
            // 1 不認得的 key、2 格式不合、3 超出範圍；記下來讓設定程式下次讀取時知道。
            if (rc != 0) prefErrors_ += key + "=" + std::to_string(rc) + ";";
        }
        dirty_ = true;
        pump();
    }

    // 狀態列（系統匣）上輸入法圖示旁的文字：英數模式時顯示「英」。
    std::string subMode(const fcitx::InputMethodEntry &, fcitx::InputContext &) override {
        return (ready_ && vg_is_ascii_mode()) ? "英數" : "";
    }

    std::string subModeLabelImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &) override {
        return (ready_ && vg_is_ascii_mode()) ? "英" : "";
    }

    void selectCandidate(fcitx::InputContext *inputContext, int index) {
        inputContext_ = inputContext->watch();
        vg_candidate_select(index);
        pump();
    }

    // 滑鼠點了選字視窗的翻頁箭頭。這時 fcitx5 還在用那份候選字清單，不能當場重畫（會把它刪掉），
    // 所以只記下來，由定時器在下一輪處理。
    void requestPage(int delta) { pendingPage_ += delta; }

private:
    static bool prefBool(const char *key) { return takeString(vg_pref_get(key)) == "true"; }

    static void onCommit(void *context, const char *text) {
        auto *self = static_cast<VanguardEngine *>(context);
        VANGUARD_DEBUG() << "commit: " << text;
        if (auto *inputContext = self->inputContext_.get()) inputContext->commitString(text);
    }

    // 一次按鍵可能觸發很多次更新，這裡只記下來，等 pump() 結束時一起畫。
    static void onUpdate(void *context) { static_cast<VanguardEngine *>(context)->dirty_ = true; }

    // 單獨按一下 Shift（中間沒有按別的鍵）切換英數模式。回傳 true 表示這個事件處理完了。
    // 注意：fcitx5 預設把左 Shift 設成「暫時切換到第一個輸入法」（全域設定的 AltTriggerKeys），
    // 那個設定開著時左 Shift 在放開前就被 fcitx5 攔走，這裡只會收到右 Shift。
    bool handleShiftTap(fcitx::KeyEvent &keyEvent) {
        const fcitx::Key key = keyEvent.rawKey();
        const bool isShift = key.sym() == FcitxKey_Shift_L || key.sym() == FcitxKey_Shift_R;
        if (!keyEvent.isRelease()) {
            const auto others = key.states().unset(fcitx::KeyState::Shift)
                                    .unset(fcitx::KeyState::NumLock)
                                    .unset(fcitx::KeyState::CapsLock);
            if (isShift && others == fcitx::KeyStates()) {
                shiftDown_ = key.sym();
                shiftDownAt_ = fcitx::now(CLOCK_MONOTONIC);
            } else {
                shiftDown_ = FcitxKey_None;
            }
            return false;
        }
        const bool tapped = isShift && key.sym() == shiftDown_ &&
                            fcitx::now(CLOCK_MONOTONIC) - shiftDownAt_ <= kShiftTapMaxUsec;
        shiftDown_ = FcitxKey_None;
        if (!tapped) return false;

        auto *inputContext = keyEvent.inputContext();
        inputContext_ = inputContext->watch();
        if (vg_toggle_ascii(key.sym() == FcitxKey_Shift_R ? 1 : 0) < 0) return false;
        dirty_ = true;
        pump();
        inputContext->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
        return true;
    }

    void pump() {
        if (pendingPage_ != 0) {
            const int delta = std::exchange(pendingPage_, 0);
            for (int i = 0; i < std::abs(delta); i++) {
                vg_key_down(delta > 0 ? FcitxKey_Page_Down : FcitxKey_Page_Up, 0);
            }
            dirty_ = true;
        }
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

        // 模式切換之類的提示，畫在選字視窗最上面那一列。
        const std::string hint = takeString(vg_hint_text());
        if (!hint.empty()) panel.setAuxUp(fcitx::Text(hint));

        // 引擎自己分頁，這裡只把目前這一頁交給 fcitx5 畫。
        const int32_t count = vg_candidates_visible() ? vg_candidate_count() : 0;
        if (count > 0) {
            auto list = std::make_unique<VanguardCandidateList>(this, vg_candidate_page_index(),
                                                                vg_candidate_page_count());
            // 橫排或直排跟著引擎的偏好設定 UseHorizontalCandidateList。
            list->setLayoutHint(vg_candidate_layout_horizontal() ? fcitx::CandidateLayoutHint::Horizontal
                                                                 : fcitx::CandidateLayoutHint::Vertical);
            list->setPageSize(count);
            std::vector<std::string> labels;
            for (int32_t i = 0; i < count; i++) {
                labels.push_back(takeString(vg_candidate_label(i)) + ". ");
                list->append<VanguardCandidateWord>(this, takeString(vg_candidate_text(i)), i);
            }
            list->setLabels(labels);
            const int32_t highlighted = vg_candidate_highlighted();
            if (highlighted >= 0) list->setGlobalCursorIndex(highlighted);
            // 頁碼與反白那個字的 Unicode 碼位，仿 macOS 版選字窗底下那一列。
            // fcitx5 的選字視窗沒有頁碼欄位，只能放在輔助文字列。
            std::string footer = std::to_string(vg_candidate_page_index() + 1) + "/" +
                                 std::to_string(vg_candidate_page_count());
            // 碼位要不要顯示，跟著引擎的偏好設定 ShowCodePointInCandidateUI。
            if (highlighted >= 0 && prefBool("ShowCodePointInCandidateUI")) {
                const std::string codePoint = codePointLabel(takeString(vg_candidate_text(highlighted)));
                if (!codePoint.empty()) footer += "  " + codePoint;
            }
            panel.setAuxDown(fcitx::Text(footer));
            panel.setCandidateList(std::move(list));
        }

        inputContext->updatePreedit();
        inputContext->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    }

    fcitx::Instance *instance_;
    bool ready_ = false;
    bool dirty_ = false;
    bool lexiconReported_ = false;
    int pendingPage_ = 0;
    mutable VanguardConfig config_;
    mutable VanguardPrefsConfig prefsConfig_;
    std::string prefErrors_;
    std::string userDataDir_;
    fcitx::KeySym shiftDown_ = FcitxKey_None;
    uint64_t shiftDownAt_ = 0;
    // 引擎目前在服務的輸入情境。第一版所有情境共用一個引擎 session。
    fcitx::TrackableObjectReference<fcitx::InputContext> inputContext_;
    std::unique_ptr<fcitx::EventSourceTime> pumpTimer_;
};

void VanguardCandidateList::prev() { engine_->requestPage(-1); }
void VanguardCandidateList::next() { engine_->requestPage(1); }

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

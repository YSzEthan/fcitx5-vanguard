cmake_minimum_required(VERSION 3.21)
project(fcitx5-vanguard VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Fcitx5Core 5.1 REQUIRED)
include(GNUInstallDirs)

# 引擎不在這裡編。先用 packaging/stage-engine.sh 產生「引擎目錄」（或解開它的 tarball），
# 裡面有 lib/（引擎與 Swift 執行期）、share/（辭庫等資料）、include/、licenses/。
set(VANGUARD_ENGINE_BUNDLE "${CMAKE_CURRENT_SOURCE_DIR}/../dist/engine"
    CACHE PATH "packaging/stage-engine.sh 產生的引擎目錄")
if(NOT EXISTS "${VANGUARD_ENGINE_BUNDLE}/lib/libVGEngine.so")
  message(FATAL_ERROR "VANGUARD_ENGINE_BUNDLE=${VANGUARD_ENGINE_BUNDLE} 裡沒有 lib/libVGEngine.so，"
                      "請先執行 packaging/stage-engine.sh 或解開引擎 tarball。")
endif()

# 引擎與 Swift 執行期裝在自己的目錄，不放進系統的函式庫搜尋路徑，免得跟別的 Swift 安裝互相干擾。
set(VANGUARD_PRIVATE_LIBDIR "${CMAKE_INSTALL_LIBDIR}/fcitx5-vanguard")
set(VANGUARD_DATADIR "${CMAKE_INSTALL_DATADIR}/fcitx5-vanguard")
set(VANGUARD_DEFAULT_TEXTMAP "${CMAKE_INSTALL_PREFIX}/${VANGUARD_DATADIR}/vanguardTextMap.txtMap"
    CACHE FILEPATH "環境變數 FCITX5_VANGUARD_TEXTMAP 沒設時使用的辭庫路徑")

add_library(VGEngine SHARED IMPORTED)
set_target_properties(VGEngine PROPERTIES
  IMPORTED_LOCATION "${VANGUARD_ENGINE_BUNDLE}/lib/libVGEngine.so"
  IMPORTED_SONAME "libVGEngine.so"
  INTERFACE_INCLUDE_DIRECTORIES "${VANGUARD_ENGINE_BUNDLE}/include")

add_library(vanguard MODULE src/vanguard.cpp)
target_link_libraries(vanguard PRIVATE Fcitx5::Core VGEngine)
target_compile_definitions(vanguard PRIVATE
  VANGUARD_DEFAULT_TEXTMAP="${VANGUARD_DEFAULT_TEXTMAP}")
target_compile_options(vanguard PRIVATE -Wall -Wextra)
# 外掛裝在 <libdir>/fcitx5/，引擎在 <libdir>/fcitx5-vanguard/，用相對路徑找，整包可以搬到別的前綴。
# libVGEngine.so 會再帶出 libVanguard.so 與 Swift 執行期，連結時要讓 ld 找得到它們。
set_target_properties(vanguard PROPERTIES
  PREFIX ""
  INSTALL_RPATH "$ORIGIN/../fcitx5-vanguard")
target_link_options(vanguard PRIVATE "LINKER:-rpath-link,${VANGUARD_ENGINE_BUNDLE}/lib")

install(TARGETS vanguard DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")
install(DIRECTORY "${VANGUARD_ENGINE_BUNDLE}/lib/" DESTINATION "${VANGUARD_PRIVATE_LIBDIR}"
        FILES_MATCHING PATTERN "*.so")
install(DIRECTORY "${VANGUARD_ENGINE_BUNDLE}/share/" DESTINATION "${VANGUARD_DATADIR}")
install(DIRECTORY "${VANGUARD_ENGINE_BUNDLE}/licenses/" DESTINATION "${VANGUARD_DATADIR}/licenses")
# 獨立的設定程式（Python + GTK 4）與它用的翻譯表。
set(VANGUARD_SETTINGS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../settings")
install(PROGRAMS "${VANGUARD_SETTINGS_DIR}/fcitx5-vanguard-settings" DESTINATION "${CMAKE_INSTALL_BINDIR}")
install(FILES "${VANGUARD_SETTINGS_DIR}/strings/zh-Hant.strings" DESTINATION "${VANGUARD_DATADIR}/settings")
install(FILES "${VANGUARD_SETTINGS_DIR}/strings/LICENSE.txt" "${VANGUARD_SETTINGS_DIR}/strings/README.md"
        DESTINATION "${VANGUARD_DATADIR}/licenses/vChewing-macOS-strings")
install(FILES "${VANGUARD_SETTINGS_DIR}/org.fcitx.Fcitx5.Addon.Vanguard.Settings.desktop"
        DESTINATION "${CMAKE_INSTALL_DATADIR}/applications")

install(FILES data/vanguard-addon.conf RENAME vanguard.conf
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon")
install(FILES data/vanguard-im.conf RENAME vanguard.conf
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/inputmethod")

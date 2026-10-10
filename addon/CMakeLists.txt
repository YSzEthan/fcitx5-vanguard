cmake_minimum_required(VERSION 3.21)
project(fcitx5-vanguard VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Fcitx5Core 5.1 REQUIRED)
include(GNUInstallDirs)

# 引擎的 C 匯出層（Swift 動態庫）先用 `swift build` 編好，這裡只連結它。
set(VANGUARD_ENGINE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../engine/.build/debug"
    CACHE PATH "含有 libVGEngine.so 與 libVanguard.so 的目錄")
set(VANGUARD_DEFAULT_TEXTMAP "${CMAKE_INSTALL_FULL_DATADIR}/fcitx5-vanguard/vanguardTextMap.txtMap"
    CACHE FILEPATH "環境變數 FCITX5_VANGUARD_TEXTMAP 沒設時使用的辭庫路徑")

add_library(VGEngine SHARED IMPORTED)
set_target_properties(VGEngine PROPERTIES
  IMPORTED_LOCATION "${VANGUARD_ENGINE_DIR}/libVGEngine.so"
  IMPORTED_NO_SONAME ON
  INTERFACE_INCLUDE_DIRECTORIES "${CMAKE_CURRENT_SOURCE_DIR}/../engine/include")

add_library(vanguard MODULE src/vanguard.cpp)
target_link_libraries(vanguard PRIVATE Fcitx5::Core VGEngine)
target_compile_definitions(vanguard PRIVATE
  VANGUARD_DEFAULT_TEXTMAP="${VANGUARD_DEFAULT_TEXTMAP}")
target_compile_options(vanguard PRIVATE -Wall -Wextra)
# 原型階段：直接從引擎的編譯目錄載入。正式打包時要改成跟著外掛一起安裝。
set_target_properties(vanguard PROPERTIES
  PREFIX ""
  INSTALL_RPATH "${VANGUARD_ENGINE_DIR}")

install(TARGETS vanguard DESTINATION "${CMAKE_INSTALL_LIBDIR}/fcitx5")
install(FILES data/vanguard-addon.conf RENAME vanguard.conf
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/addon")
install(FILES data/vanguard-im.conf RENAME vanguard.conf
        DESTINATION "${CMAKE_INSTALL_DATADIR}/fcitx5/inputmethod")

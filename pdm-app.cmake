#
# Declares this repository as a PdM Maestro app.
#
# Maestro's top-level CMakeLists.txt compiles an app in only when this file is
# present, so a submodule that is checked out but not yet ported keeps its
# placeholder tab instead of breaking the shell's build. The variables below are
# read by Maestro; nothing in this repository uses them.
#
set(PDM_APP_ID       "ota")
set(PDM_APP_TARGET   "pdm_ota")
set(PDM_APP_PLUGIN   "pdm_otaplugin")
set(PDM_APP_QML_URI  "PdM.Ota")

# The macro Maestro's main.cpp checks before calling registerWithShell().
set(PDM_APP_DEFINE   "PDM_HAVE_OTA")

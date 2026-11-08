# Override only the unsafe Darwin writer; keep the pinned upstream source intact.
get_target_property(dobby_sources dobby_static SOURCES)
list(FILTER dobby_sources EXCLUDE REGEX "code-patch-tool-darwin[.]cc$")
set_property(TARGET dobby_static PROPERTY SOURCES "${dobby_sources}")
target_sources(dobby_static PRIVATE "${CMAKE_CURRENT_LIST_DIR}/dobby_code_patch_darwin.cpp")
add_executable(FluentCodePatchProbe "${CMAKE_CURRENT_LIST_DIR}/code_patch_probe.cpp")
target_link_libraries(FluentCodePatchProbe PRIVATE dobby_static)

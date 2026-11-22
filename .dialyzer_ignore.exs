# Warnings that dialyzer accepts to keep. Each entry pins ONE warning of
# ONE file at ONE line, with the reason — a file-wide entry would hide a
# new finding of the same type elsewhere in the file. The goal is an
# empty list: an entry goes away when the code changes so that the
# warning is gone.
[
  #
  # `ref` comes from the struct of the standard `Task` module. Its type
  # `Task.ref/0` is opaque, but a reference is what it is and
  # `Process.demonitor/2` takes it. Not fixable here; the three call
  # sites are pinned so a new demonitor of a Task ref elsewhere in this
  # file still reports.
  {"lib/oz_mcp/handler/invoke.ex", :call_with_opaque, 334},
  {"lib/oz_mcp/handler/invoke.ex", :call_with_opaque, 411},
  {"lib/oz_mcp/handler/invoke.ex", :call_with_opaque, 424},
  #
  # Helpers whose only job is to raise on invalid input. `no_return` is
  # what they are for; the warnings are pinned to their lines.
  {"lib/oz_mcp/notify.ex", :no_return, 374},
  {"lib/oz_mcp/structs/elicitation_schema.ex", :no_return, 144},
  {"lib/oz_mcp/structs/enum_options.ex", :no_return, 74},
  {"lib/oz_mcp/config/dsl/type.ex", :no_return, 114},
  {"lib/oz_mcp/config/dsl/type.ex", :no_return, 110},
  #
  # Catch-all `other` clauses after every answer shape the `@spec`s of
  # the session calls name. Dialyzer proves they cannot match today, but
  # a user-supplied session store may answer a shape outside the spec;
  # the clauses route that to a graceful pipeline halt instead of a
  # CaseClauseError. Pinned per clause line.
  {"lib/oz_mcp/validate/http.ex", :pattern_match_cov, 156},
  {"lib/oz_mcp/validate/http.ex", :pattern_match_cov, 173},
  {"lib/oz_mcp/validate/http.ex", :pattern_match_cov, 273},
  {"lib/oz_mcp/validate/http.ex", :pattern_match_cov, 352}
]

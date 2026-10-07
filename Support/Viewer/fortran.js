/* Fortran for Prism — Marina's own, written fresh (upstream Prism has none).

   Two languages, because the forms disagree about column 1. In fixed form
   (.f, .for, .f77) a C, c or * there makes the line a comment; in free form
   (.f90 and later) that same "c" is the start of `c = a + b`. One grammar would
   either miss old comments or eat new code. Everything is case-insensitive:
   Fortran is, and real code mixes INTEGER, Integer and integer freely. */
(function (Prism) {
  var keywords = [
    "program", "module", "submodule", "end", "subroutine", "function", "contains",
    "use", "only", "implicit", "none", "integer", "real", "double", "precision",
    "complex", "character", "logical", "type", "class", "parameter", "dimension",
    "allocatable", "pointer", "target", "intent", "in", "out", "inout", "optional",
    "save", "public", "private", "protected", "interface", "procedure", "call",
    "return", "if", "then", "else", "elseif", "endif", "do", "enddo", "while",
    "select", "case", "default", "where", "elsewhere", "forall", "exit", "cycle",
    "stop", "go", "goto", "continue", "allocate", "deallocate", "nullify",
    "associate", "block", "data", "common", "equivalence", "external", "intrinsic",
    "include", "format", "open", "close", "read", "write", "print", "inquire",
    "rewind", "backspace", "recursive", "pure", "elemental", "impure", "result",
    "kind", "len", "sequence", "abstract", "extends", "nopass", "pass", "final",
    "generic", "import", "value", "volatile", "entry", "namelist", "concurrent",
    "critical", "sync", "all", "images", "deferred", "non_overridable", "enum",
    "enumerator", "bind", "error", "endmodule", "endsubroutine", "endfunction",
    "endprogram", "endtype", "endinterface", "endselect", "endwhere", "endblock",
  ];
  var builtins = [
    "abs", "sqrt", "exp", "log", "log10", "sin", "cos", "tan", "asin", "acos",
    "atan", "atan2", "sinh", "cosh", "tanh", "min", "max", "mod", "modulo", "sign",
    "int", "nint", "floor", "ceiling", "dble", "cmplx", "aimag", "conjg", "size",
    "shape", "lbound", "ubound", "sum", "product", "maxval", "minval", "maxloc",
    "minloc", "any", "count", "allocated", "associated", "present", "trim",
    "adjustl", "adjustr", "len_trim", "index", "scan", "verify", "repeat",
    "reshape", "transpose", "matmul", "dot_product", "spread", "pack", "unpack",
    "merge", "huge", "tiny", "epsilon", "selected_real_kind", "selected_int_kind",
    "real64", "real32", "int32", "int64", "iso_fortran_env", "iso_c_binding",
  ];
  var word = function (list) {
    return new RegExp("\\b(?:" + list.join("|") + ")\\b", "i");
  };

  Prism.languages.fortran = {
    comment: { pattern: /!.*/, greedy: true },
    // quotes escape by doubling: 'don''t'
    string: { pattern: /(["'])(?:\1\1|(?!\1)[^\r\n])*\1/, greedy: true },
    boolean: /\.(?:true|false)\.(?:_\w+)?/i,
    // .eq. and friends are words between dots, and must win over "keyword"
    operator: /\.(?:eq|ne|lt|le|gt|ge|not|and|or|eqv|neqv)\.|\*\*|\/\/|=>|==|\/=|<=|>=|[<>=+\-*\/%]/i,
    number: /(?:\b\d+(?:\.\d*)?|\B\.\d+)(?:[dDeEqQ][+-]?\d+)?(?:_\w+)?\b/,
    keyword: word(keywords),
    builtin: word(builtins),
    punctuation: /[(),:;&]/,
  };

  // a copy, then the column-1 rule ahead of everything else in it — inserting
  // into "fortran" itself would make free-form `c = a + b` a comment
  Prism.languages["fortran-fixed"] = Prism.languages.extend("fortran", {});
  Prism.languages.insertBefore("fortran-fixed", "comment", {
    "fixed-comment": { pattern: /^[cC*].*$/m, alias: "comment", greedy: true },
  });
})(Prism);

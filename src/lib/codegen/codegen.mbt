pub fn codegen_lex(lex : Lex) -> String {
  [
    runtime,
    lex.header,
    lex.rules.map(codegen_rule) |> String::concat(separator="\n"),
    lex.trailer,
  ]
  |> String::concat(separator="\n\n")
  |> fix_indent
}

fn rewrite_codeblock(
  codeblock : @type.CodeBlock,
  subst : Array[@codeblock_parser.SubstItem]
) -> @type.CodeBlock {
  let buf = StringBuilder::new()
  let mut last_index = 0
  for item in subst {
    // replace `$startpos(t)`/`$endpos(t)` with `_start_pos_of_t`/`_end_pos_of_t`
    buf.write_substring(codeblock, last_index, item.start - last_index)
    match item.desc {
      StartPosOf(name) => buf.write_string("_start_pos_of_\{name}")
      EndPosOf(name) => buf.write_string("_end_pos_of_\{name}")
    }
    last_index = item.end
  }
  if last_index < codeblock.length() {
    buf.write_substring(codeblock, last_index, codeblock.length() - last_index)
  }
  buf.to_string()
}

fn codegen_rule(rule : Rule) -> String {
  let dfa = @automaton.DFA::from_rule(rule)
  let engine = "__mbtlex_engine_\{rule.name}"
  let graph : Array[Array[(Int, Array[Array[Int]])]] = dfa.graph.map(
    fn(mp) {
      Array::makei(
        128,
        fn(i) {
          mp
          .get(Char::from_int(i))
          .map_or((0, []), fn(pair) { (pair.0, pair.1._) })
        },
      )
    },
  )
  let end_nodes : Array[(Int, Array[((Int, Int), (Int, Int))])?] = Array::makei(
    dfa.node_count,
    fn(i) { dfa.end_nodes.get(i) },
  )
  let start_tags : Array[Int] = []
  for index, action in dfa.start_action._ {
    if not(action.is_empty()) {
      start_tags.push(index)
    }
  }
  [
    "let \{engine}: Engine = { graph: \{graph}, end_nodes: \{end_nodes}, start_tags: \{start_tags}, code_blocks_n: \{dfa.code_blocks.length()} }",
    [
      "fn \{rule.name}(",
      [..rule.vars, { identifier: "lexbuf", ty: "Lexbuf" }].map(
        fn(p) { "\{p.identifier} : \{p.ty}" },
      )
      |> String::concat(separator=", "),
      ")",
      "->",
      rule.return_type,
      "{",
    ]
    |> String::concat(separator=" "),
    [
      ["match \{engine}.run(lexbuf) {"],
      Array::makei(
        dfa.code_blocks.length(),
        fn(i) {
          let codeblock = dfa.code_blocks[i]
          let subst = @codeblock_parser.parse_codeblock(codeblock)
          fn name_used_in_subst(name : String) -> Bool {
            for item in subst {
              match item.desc {
                StartPosOf(n) | EndPosOf(n) => if n == name { return true }
              }
            }
            false
          }

          [
            ["(\{i}, __mbtlex_captures) => {"],
            dfa.captures[i].mapi(
              fn(i, name) {
                let inject_ignore = if name_used_in_subst(name) {
                  "ignore(\{name})"
                } else {
                  ""
                }
                $|let (_start_pos_of_\{name}, _end_pos_of_\{name}) = __mbtlex_captures[\{i}]
                $|let \{name}: String = lexbuf.substring(_start_pos_of_\{name}, _end_pos_of_\{name})
                $|\{inject_ignore}
              },
            ),
            [rewrite_codeblock(codeblock, subst)],
            ["}"],
          ]
          |> flatten()
          |> String::concat(separator="\n")
        },
      ),
      ["_ => abort(\"lex: fail to match\")"],
      ["}"],
    ]
    |> flatten()
    |> String::concat(separator="\n"),
    "}",
  ]
  |> String::concat(separator="\n")
}

fn fix_indent(code : String) -> String {
  // fix indent for the generated code
  // since moonbit require the toplevel definition at the head of line 
  // and the others not

  let code = "\n" + code
  let mut ptr = 0
  let mut indent_count = 0
  let buf = StringBuilder::new(size_hint=code.length())
  while ptr < code.length() {
    let ch = code[ptr]
    ptr += 1
    buf.write_char(ch)
    match ch {
      '\n' =>
        if indent_count == 0 {
          while ptr < code.length() && ['\t', ' '].contains(code.get(ptr)) {
            ptr += 1
          }
        } else {
          buf.write_char(' ')
        }
      '{' => indent_count += 1
      '}' => indent_count -= 1
      '\\' =>
        if ptr < code.length() {
          buf.write_char(code.get(ptr))
          ptr += 1
        }
      '\"' =>
        while ptr < code.length() {
          let ch = code.get(ptr)
          buf.write_char(code.get(ptr))
          if code.get(ptr) == '\\' {
            if ptr + 1 < code.length() {
              buf.write_char(code.get(ptr + 1))
            }
            ptr += 2
          } else {
            ptr += 1
          }
          if ch == '\"' {
            break
          }
        }
      _ => ()
    }
  }
  buf.to_string()
}

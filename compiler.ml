open Format
open X86_64
open Ast
open Precompiled_ast

let int_of_bool b = if b then 1 else 0

let data_count = ref (-1)
let data_seg = ref nop
let register_data str =
  data_count := !data_count + 1;
  let id = "_str_" ^ (string_of_int !data_count) in
  data_seg := label id ++ string str ++ !data_seg;
  id

let data_count = ref (-1)
let register_if () =
  data_count := !data_count + 1;
  let s = string_of_int !data_count in
  ("_else_" ^ s, "_endif_" ^ s)
let register_while () =
  data_count := !data_count + 1;
  let s = string_of_int !data_count in
  ("_while_" ^ s, "_endwhile_" ^ s)

let pushn size =
  subq (imm (size * 8)) (reg rsp)
let popn size =
  addq (imm (size * 8)) (reg rsp)

let memmove (f,fr) (t,tr) s =
  movq (imm s) (reg rdx) ++
  leaq (ind ~ofs:(8 * f) fr) rsi ++
  leaq (ind ~ofs:(8 * t) tr) rdi ++
  call "_memmove"

(* extended push *)
let epush (f,fr) size =
  pushn size ++
  memmove (f,fr) (0,rsp) size

let size_of = Precompiler.size_of

(* sets rdi to rbp d levels above *)
let rec reach_depth = function
  | 0 -> movq (reg rbp) (reg rdi)
  | d -> reach_depth (d-1) ++
    movq (ind rdi) (reg rdi)

let lib =
  (* rdi : string label *)
  label "_print" ++
  movq (imm 0) (reg rax) ++
  call "printf" ++
  ret ++

  (* rdi : destination address
   * rsi : source address
   * rdx : size to copy *)
  label "_memmove" ++
  xorq (reg rcx) (reg rcx) ++
  label "_memmove_loop" ++
  movq (ind ~index:rcx ~scale:8 rsi) (reg r15) ++
  movq (reg r15) (ind ~index:rcx ~scale:8 rdi) ++
  incq (reg rcx) ++
  cmpq (reg rdx) (reg rcx) ++
  jb "_memmove_loop" ++
  ret

let rec compile_l_value_address = function
  | PIdent ((d,ofs), _) ->
      reach_depth d ++
      leaq (ind ~ofs:(8 * ofs) rdi) rax
  | PDot (e, o, _, _) ->
      compile_l_value_address e ++
      addq (imm (8 * o)) (reg rax)
  | _ -> assert false

let rec compile_expr = function
  | PInt i ->
      pushq (imm i)
  | PBool b ->
      pushq (imm (int_of_bool b))
  | PIdent ((d,ofs), ty) ->
      reach_depth d ++
      epush (ofs,rdi) (size_of ty)
  | PUnop (Minus, PInt i, _) ->
      pushq (imm (-i))
  | PUnop (op, e, _) ->
      compile_expr e ++
      begin match op with
      | Minus ->
          popq rbx ++
          movq (imm 0) (reg rax) ++
          subq (reg rbx) (reg rax) ++
          pushq (reg rax)
      | Bang ->
          popq rax ++
          movq (imm 0) (reg r9) ++
          testq (reg rax) (reg rax) ++
          sete (reg r9b) ++
          pushq (reg r9)
      | Star | Amp | AmpMut -> assert false
      end
  | PAssignement (e1, e2, t) ->
      compile_l_value_address e1 ++
      movq (reg rax) (reg r14) ++
      compile_expr e2 ++
      memmove (0,rsp) (0,r14) (size_of t) ++
      popn (size_of t) ++
      pushq (imm 0)
  | PBinop (And as b, e1, e2, _) | PBinop (Or as b, e1, e2, _) ->
      let _else, _end = register_if () in
      compile_expr e1 ++
      popq rbx ++
      testq (reg rbx) (reg rbx) ++
      (match b with | And -> jz | Or -> jnz | _ -> assert false) _else ++
      compile_expr e2 ++
      jmp _end ++
      label _else ++
      pushq (reg rbx) ++
      label _end
  | PBinop (op, e1, e2, _) ->
      let compare setter =
        movq (imm 0) (reg r9) ++
        cmpq (reg rbx) (reg rax) ++
        setter (reg r9b) ++
        movq (reg r9) (reg rax) in
      compile_expr e1 ++
      compile_expr e2 ++
      popq rbx ++ popq rax ++
      begin match op with
      | Add -> addq (reg rbx) (reg rax)
      | Sub -> subq (reg rbx) (reg rax)
      | Mul -> imulq (reg rbx) (reg rax)
      | Div -> cqto ++ idivq (reg rbx)
      | Mod ->
          cqto ++ idivq (reg rbx) ++
          movq (reg rdx) (reg rax)
      | Eq  -> compare sete
      | Neq -> compare setne
      | Geq -> compare setge
      | Leq -> compare setle
      | Gt  -> compare setg
      | Lt  -> compare setl
      | And | Or | Equal -> assert false
      end ++ pushq (reg rax)
  | PDot (e, o, s, t) ->
      compile_expr e ++
      memmove (o,rsp) (size_of s - size_of t,rsp) (size_of t) ++
      pushn (size_of t) ++
      popn (size_of s)
  | PLen (e, t) -> assert false
  | PBrackets (eo, ei, t) -> assert false
  | PFunCall (f, el, arg_size, t) ->
      pushn (size_of t) ++
      List.fold_left (++) nop (List.rev (List.map compile_expr el)) ++
      call f ++
      popn arg_size
  | PPrint s ->
      let id = register_data s in
      movq (ilab id) (reg rdi) ++
      call "_print" ++
      pushq (imm 0)
  | PBloc b -> compile_bloc b
  | _ -> assert false
and compile_bloc (instr, expr, vars_size, t) =
  pushn (size_of t) ++
  pushq (reg rbp) ++
  movq (reg rsp) (reg rbp) ++
  (if vars_size > 0 then pushn vars_size else nop) ++
  List.fold_left (++) nop (List.map compile_instr instr) ++
  begin match expr with
    | None -> if List.length instr > 0 &&
      (match Typer.last instr with | PIf _ -> true | _ -> false)
      then pushn (size_of t)
      else pushq (imm 0)
    | Some e -> compile_expr e
  end ++
  memmove (0, rsp) (1, rbp) (size_of t) ++
  popn (size_of t) ++
  (if vars_size > 0 then
    popn vars_size
  else nop) ++
  popq rbp

and compile_instr = function
  | PEmpty -> nop
  | PExpr (e,t) ->
      compile_expr e ++
      popn (size_of t)
  | PLet ((_,i), e, t) ->
      let t = size_of t in
      compile_expr e ++
      memmove (0,rsp) (i,rbp) t ++
      popn t
  | PLetStruct ((_,ofs), vars, t) ->
      let compile_var (i, e, s) =
        compile_expr e ++
        memmove (0, rsp) (ofs + i, rbp) s in
      List.fold_left (++) nop (List.map compile_var vars) ++
      popn (size_of t)
  | PWhile (c, b) ->
      let _cond, _end = register_while () in
      label _cond ++
      compile_expr c ++
      popq rax ++
      testq (reg rax) (reg rax) ++
      jz _end ++
      compile_bloc b ++
      popn 1 ++
      jmp _cond ++
      label _end
  | PIf (c, t, e, ty) ->
      let _else, _end = register_if () in
      compile_expr c ++
      popq rax ++
      testq (reg rax) (reg rax) ++
      jz _else ++
      compile_bloc t ++
      jmp _end ++
      label _else ++
      compile_bloc e ++
      label _end ++
      popn (size_of ty)
  | _ -> assert false

let compile_decl = function
  | PDeclStruct -> nop
  | PDeclFun (f, bloc, arg_size, t) ->
      label f ++
      compile_bloc bloc ++
      memmove (0, rsp) (2 + arg_size, rsp) (size_of t) ++
      popn (size_of t) ++
      ret

let compile_program p out_file =
  let p = Precompiler.precompile p in
  let code = List.fold_left (++) nop (List.map compile_decl p) in
  let p =
    { text =
        globl "main" ++ label "main" ++
        (* initialize *)
        pushq (imm 0) ++
        movq (reg rsp) (reg rbp) ++
        (* main code *)
        (call "_main") ++
        popq rax ++
        (* exit 0 *)
        movq (imm 0) (reg rax) ++
        ret ++
        (* external calls *)
        lib ++
        (* functions code *)
        code;
      data = !data_seg;
    } in
  let f = open_out out_file in
  let fmt = formatter_of_out_channel f in
  X86_64.print_program fmt p;
  fprintf fmt "@?";
  close_out f

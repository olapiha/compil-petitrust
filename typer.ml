open Ast
open Typed_ast

exception Typing_error of string

module Env = Map.Make(String)

let empty_env = (Env.empty, Env.empty, Env.empty)

let var_type (env, _, _) i = Env.find i env
let fun_type (_, env, _) f = Env.find f env
let is_struct (_, _, env) s = Env.mem s env
let has_variable (_, _, env) s i = Env.mem i (Env.find s env)
let struct_type (_, _, env) s i = Env.find i (Env.find s env)

let decl_var (env, f_env, s_env) v t = (Env.add v t env, f_env, s_env)
let decl_fun (v_env, env, s_env) f t = (v_env, Env.add f t env, s_env)
let decl_struct (v_env, f_env, env) s l =
  let s_env = List.fold_left
              (fun e (i,t) -> Env.add i t e)
              Env.empty l in
  (v_env, f_env, Env.add s s_env env)

let has_duplicate_idents l =
  try
    let add env = function
      | (x,_) when Env.mem x env -> raise Exit
      | (x,_) -> Env.add x () env in
    let _ = List.fold_left add Env.empty l in
    false
  with Exit -> true

let unop_type = function
  | Minus  -> [Int32], Int32
  | Bang   -> [Boolean], Boolean
  | Star   -> assert false
  | Amp    -> assert false
  | AmpMut -> assert false

let binop_type = function
  | Add | Sub | Mul | Div | Mod -> [Int32; Int32], Int32
  | Equal -> raise (Typing_error "Missing let keyword for equal sign")
  | Eq | Neq | Leq | Geq
  | Lt | Gt | And | Or -> [Boolean; Boolean], Boolean

let check_type t a = (t = a)

let check_args (t_arg, ret) arg =
  let rec check_rec = function
    | ([], []) -> ret
    | (t::tq, a::ta) when check_type t a -> check_rec (tq,ta)
    | (_, _) -> raise (Typing_error "Incompatible types")
  in check_rec (t_arg,arg)

let check_structure_instanciation (_, _, env) s decl =
  try
    let vars = Env.find s env in
    let fold_decl map = function
      | (id, _) when Env.mem id map ->
          raise (Typing_error ("Duplicate variable in struct : " ^ id))
      | (id, _) when not (Env.mem id vars) ->
          raise (Typing_error ("Unexpected variable in struct : " ^ id))
      | (id, t) when not (check_type t (Env.find id vars)) ->
          raise (Typing_error ("Incompatible types for variable : " ^ id))
      | (id, t) -> Env.add id t map in
    let decl_map = List.fold_left fold_decl Env.empty decl in
    let check_presence id = function
      | _ when not (Env.mem id decl_map) ->
          raise (Typing_error ("Missing variable in struct : " ^ id))
      | _ -> () in
    Env.iter check_presence vars
  with Not_found -> raise (Typing_error ("Unkown structure : " ^ s))

let type_of_expr = function
    TInt (_, t) | TBool (_, t) | TIdent (_, t)
  | TUnop (_, _, t) | TBinop (_, _, _, t)
  | TDot (_, _, t) | TLen (_, t) | TBrackets (_, _, t)
  | TFunCall (_, _, t) | TVec (_, t) | TPrint (_, t)
  | TBloc (_, t) -> t
let type_of_bloc = function
  | _, _, t -> t

let type_keywords = [ "i32", Int32; "()", Unit; "bool", Boolean]
let rec expr_type_of_type env (x : Ast._type) = match x with
  | Ident i ->
    begin
      try
        List.assoc i type_keywords
      with Not_found ->
        if is_struct env i then
          Struct i
        else raise (Typing_error "Unkown type")
    end
  | TypedIdent (i, t) ->
      if i = "Vec" then
        Vect (expr_type_of_type env t)
      else raise (Typing_error "Unknown bracket type")
  | AddressOfMut t -> Ref (true, expr_type_of_type env t)
  | AddressOf t ->    Ref (false, expr_type_of_type env t)

let expr_type_of_type_option env = function
  | None -> Unit
  | Some t -> expr_type_of_type env t

let type_file file =
  let fold_env typer env =
    List.fold_left (fun (l, env) x ->
      let tx, n_env = typer env x in (tx::l, n_env))
    ([], env) in
  let rec type_decl env = function
    | DeclStruct (i, l) ->
        if has_duplicate_idents l then
          raise (Typing_error ("Duplicate variable name in struct : " ^ i))
        else
          let n_arg = List.map (fun (x,y) -> (x, expr_type_of_type env y)) l in
          let n_env = decl_struct env i n_arg in
          TDeclStruct (i, n_arg, Unit), n_env
    | DeclFun (i, l, t, b) ->
        if has_duplicate_idents (List.map (fun (_,x,y) -> (x,y)) l) then
          raise (Typing_error ("Duplicate variable name in function : " ^ i))
        else
          let ret_type = expr_type_of_type_option env t in
          let arg_type = List.map (fun (x,y,z) -> expr_type_of_type env z) l in
          let n_env = decl_fun env i (arg_type, ret_type) in
          let n_arg = List.map (fun (x,y,z) -> (x, y, expr_type_of_type env z)) l in
          TDeclFun (i, n_arg, ret_type, fst (type_bloc env b), Unit), n_env
  and type_expr env = function
    | Int i -> TInt (i, Int32), env
    | Bool b -> TBool (b, Boolean), env
    | Ident i ->
        begin
          try TIdent (i, var_type env i), env
          with Not_found -> raise (Typing_error "Undefined litteral")
        end
    | Unop (u, e) ->
        begin
          let te, _ = type_expr env e in
          let r = match u with
          | Star -> begin
                    match type_of_expr te with
                    | Ref (_, t) -> t
                    | _ -> raise (Typing_error "Expected reference type")
                    end
          | Amp -> Ref (false, type_of_expr te)
          | AmpMut -> Ref (true, type_of_expr te)
          | _ -> check_args (unop_type u) [(type_of_expr te)]
          in TUnop(u, te, r), env
        end
    | Binop (b, e1, e2) ->
        let te1, _ = type_expr env e1
        and te2, _ = type_expr env e2
        in let r = check_args (binop_type b) (List.map type_of_expr [te1; te2])
        in TBinop (b, te1, te2, r), env
    | Dot (e, i) ->
        let te = fst (type_expr env e) in
        begin
          match type_of_expr te with
          | Struct s ->
              if has_variable env s i then
                TDot (te, i, struct_type env s i), env
              else raise (Typing_error ("Unkown variable " ^ i ^ " for struct " ^ s))
          | _ -> raise (Typing_error "Cannot call . on non-struct type")
        end
    | Len e ->
        let te = fst (type_expr env e) in
        begin
          match type_of_expr te with
          | Vect t -> TLen (te, Int32), env
          | _ -> raise (Typing_error "Cannot call len on non-vec type")
        end
    | Brackets (eo, ei) ->
        let teo = fst (type_expr env eo) in
        let tei = fst (type_expr env ei) in
        begin
          match type_of_expr teo with
          | Vect t -> if check_type (type_of_expr tei) Int32
                      then TBrackets (teo, tei, t), env
                      else raise (Typing_error "Expected i32 argument to [] call")
          | _ -> raise (Typing_error "Cannot call [] on non-vec type")
        end
    | FunCall (f, arg) ->
        let targ = List.map (fun x -> fst (type_expr env x)) arg
        in let r = check_args (fun_type env f) (List.map type_of_expr targ)
        in TFunCall(f, targ, r), env
    | Vec e ->
        let te = List.map (fun x -> fst (type_expr env x)) e in
        let t = List.fold_left
          (fun pt nt -> if check_type pt nt then nt
            else raise (Typing_error "Incompatible vector elements"))
          Neutral (List.map type_of_expr te) in
        TVec (te, t), env
    | Print s -> TPrint (s, Unit), env
    | Bloc b -> let tb, _ = type_bloc env b in TBloc (tb, type_of_bloc tb), env
  and type_bloc env (instr_list, expr) =
    let te = match expr with |None -> None |Some e -> Some (fst (type_expr env e)) in
    (fst (fold_env type_instr env instr_list), te, Unit), env
  and type_instr env = function
    | Empty -> TEmpty Unit, env
    | Expr e -> let te = fst (type_expr env e) in
        TExpr (te, type_of_expr te), env
    | Let (b, i, e) ->
        let te, _ = type_expr env e in
        let t = type_of_expr te in
        TLet(b, i, te, Unit), (decl_var env i t)
    | LetStruct (b, i, s, l) ->
        let tl = List.map (fun (id, ex) -> (id, fst (type_expr env ex))) l in
        let env1 = decl_var env i (Struct s) in
        let t = List.map (fun (id, te) -> (id, type_of_expr te)) tl in
        check_structure_instanciation env s t;
        TLetStruct (b, s, i, tl, Unit), env1
    | While (e, b) ->
        let te, _ = type_expr env e in
        if check_type (type_of_expr te) Boolean then
          begin
            let tb, _ = type_bloc env b in
            if check_type (type_of_bloc tb) Unit then
              TWhile (te, tb, Unit), env
            else raise (Typing_error "Expected unit bloc as while argument")
          end
        else raise (Typing_error "Expected boolean condition for while bloc")
    | Return eo ->
        let teo = begin
          match eo with
          | None -> None
          | Some e -> Some (fst (type_expr env e))
        end in TReturn (teo, Unit), env
    | If (e, b1, b2) ->
        let te, _  = type_expr env e  in
        let tb1, _ = type_bloc env b1 in
        let tb2, _ = type_bloc env b2 in
        if (check_type (type_of_expr te) Boolean) then
          if (check_type (type_of_bloc tb1) (type_of_bloc tb2)) then
            let t = type_of_bloc tb1 in TIf (te, tb1, tb2, t), env
          else raise (Typing_error "Expected same type for both blocs")
        else raise (Typing_error "Expected boolean condition for if bloc")
  in let typed_file, _ = fold_env type_decl empty_env file
  in typed_file
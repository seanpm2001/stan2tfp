open Core_kernel
open Middle

let dist_prefix = "tfd__."

let remove_stan_dist_suffix s =
  let s = Utils.stdlib_distribution_name s in
  List.filter_map
    (("_rng" :: Utils.distribution_suffices) @ [""])
    ~f:(fun suffix -> String.chop_suffix ~suffix s)
  |> List.hd_exn

let capitalize_fnames =
  String.Set.of_list
    [ "normal"; "cauchy"; "gumbel"; "exponential"; "gamma"; "beta"; "poisson"
    ; "wishart" ]

let map_functions fname args =
  let open Expr in
  match fname with
  | "multi_normal_cholesky" -> ("MultivariateNormalTriL", args)
  | "student_t" -> ("StudentT", args)
  | "double_exponential" -> ("Laplace", args)
  | "lognormal" -> ("LogNormal", args)
  | "chi_square" -> ("Chi2", args)
  | "inv_gamma" -> ("InverseGamma", args)
  | "lkj_corr_cholesky" -> ("CholeskyLKJ", args)
  | "binomial_logit" -> ("Binomial", args)
  | "bernoulli_logit" -> ("Bernoulli", args)
  | "categorical_logit" -> ("Categorical", args)
  | "von_mises" -> ("VonMises", args)
  | "binomial" -> (
    match args with
    | [y; n; p] ->
        ( "Binomial"
        , [y; n; {Fixed.pattern= Var "None"; meta= Typed.Meta.empty}; p] )
    | _ ->
        raise_s
          [%message
            " Binomial argument should contain exactly three elements."] )
  | "bernoulli" -> (
    match args with
    | [y; p] ->
        ( "Bernoulli"
        , [y; {Fixed.pattern= Var "None"; meta= Typed.Meta.empty}; p] )
    | _ ->
        raise_s
          [%message " Binomial argument should contain exactly two elements."]
    )
  | "categorical" -> (
    match args with
    | [y; p] ->
        ( "Categorical"
        , [y; {Fixed.pattern= Var "None"; meta= Typed.Meta.empty}; p] )
    | _ ->
        raise_s
          [%message
            " Categorical argument should contain exactly two elements."] )
  | "poisson_log" -> (
    match args with
    | [y; log_lambda] ->
        ( "Poisson"
        , [y; {Fixed.pattern= Var "None"; meta= Typed.Meta.empty}; log_lambda]
        )
    | _ ->
        raise_s
          [%message " Poisson argument should contain exactly two elements."] )
  | "pareto" -> (
    match args with
    | [y; y_min; alpha] -> ("Categorical", [y; alpha; y_min])
    | _ ->
        raise_s
          [%message " Pareto argument should contain exactly three elements."]
    )
  | f when Operator.of_string_opt f |> Option.is_some -> (fname, args)
  | _ ->
      if Set.mem capitalize_fnames fname then (String.capitalize fname, args)
      else raise_s [%message "Not sure how to handle " fname " yet!"]

let translate_funapps e =
  let open Expr.Fixed in
  let f ({pattern; _} as expr) =
    match pattern with
    | FunApp (StanLib, fname, args) ->
        let prefix =
          if Utils.is_distribution_name fname then dist_prefix else ""
        in
        let fname = remove_stan_dist_suffix fname in
        let fname, args = map_functions fname args in
        {expr with pattern= FunApp (StanLib, prefix ^ fname, args)}
    | _ -> expr
  in
  rewrite_bottom_up ~f e

let%expect_test "nested dist prefixes translated" =
  let open Expr.Fixed.Pattern in
  let e pattern = {Expr.Fixed.pattern; meta= Expr.Typed.Meta.empty} in
  let f =
    FunApp
      ( Fun_kind.StanLib
      , "normal_lpdf"
      , [FunApp (Fun_kind.StanLib, "normal_lpdf", []) |> e] )
    |> e |> translate_funapps
  in
  print_s [%sexp (f : Expr.Typed.Meta.t Expr.Fixed.t)] ;
  [%expect
    {|
    ((pattern
      (FunApp StanLib tfd__.Normal
       (((pattern (FunApp StanLib tfd__.Normal ()))
         (meta ((type_ UInt) (loc <opaque>) (adlevel DataOnly)))))))
     (meta ((type_ UInt) (loc <opaque>) (adlevel DataOnly)))) |}]

(* temporary until we get rid of these from the MIR *)
let rec remove_unused_stmts s =
  let pattern =
    match s.Stmt.Fixed.pattern with
    | Assignment (_, {Expr.Fixed.pattern= FunApp (CompilerInternal, f, _); _})
      when Internal_fun.to_string FnConstrain = f
           || Internal_fun.to_string FnUnconstrain = f ->
        Stmt.Fixed.Pattern.Skip
    | Decl _ -> Stmt.Fixed.Pattern.Skip
    | x -> Stmt.Fixed.Pattern.map Fn.id remove_unused_stmts x
  in
  {s with pattern}

let trans_prog (p : Program.Typed.t) =
  let rec map_stmt {Stmt.Fixed.pattern; meta} =
    { Stmt.Fixed.pattern=
        Stmt.Fixed.Pattern.map translate_funapps map_stmt pattern
    ; meta }
  in
  Program.map translate_funapps map_stmt p
  |> Program.map Fn.id remove_unused_stmts
  |> Program.map_stmts Analysis_and_optimization.Mir_utils.cleanup_empty_stmts
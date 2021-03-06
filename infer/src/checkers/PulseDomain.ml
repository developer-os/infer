(*
 * Copyright (c) 2018-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging
open Result.Monad_infix

(* {2 Abstract domain description } *)

(** An abstract address in memory. *)
module AbstractAddress : sig
  type t = private int [@@deriving compare]

  val equal : t -> t -> bool

  val mk_fresh : unit -> t

  val pp : F.formatter -> t -> unit
end = struct
  type t = int [@@deriving compare]

  let equal = [%compare.equal: t]

  let next_fresh = ref 0

  let mk_fresh () =
    let l = !next_fresh in
    incr next_fresh ; l


  let pp = F.pp_print_int
end

module Access = struct
  type t = AccessPath.access [@@deriving compare]

  let pp = AccessPath.pp_access
end

module Memory = struct
  module Edges = PrettyPrintable.MakePPMap (Access)
  module Graph = PrettyPrintable.MakePPMap (AbstractAddress)

  (* {3 Monomorphic {!PPMap} interface as needed } *)

  type t = AbstractAddress.t Edges.t Graph.t

  let empty = Graph.empty

  let find_opt = Graph.find_opt

  let for_all = Graph.for_all

  let fold = Graph.fold

  let pp = Graph.pp ~pp_value:(Edges.pp ~pp_value:AbstractAddress.pp)

  (* {3 Helper functions to traverse the two maps at once } *)

  let add_edge addr_src access addr_end memory =
    let edges =
      match Graph.find_opt addr_src memory with Some edges -> edges | None -> Edges.empty
    in
    Graph.add addr_src (Edges.add access addr_end edges) memory


  let find_edge_opt addr access memory =
    let open Option.Monad_infix in
    Graph.find_opt addr memory >>= Edges.find_opt access
end

(** to be used as maps values *)
module AbstractAddressDomain_JoinIsMin : AbstractDomain.S with type astate = AbstractAddress.t =
struct
  type astate = AbstractAddress.t

  let ( <= ) ~lhs ~rhs = AbstractAddress.equal lhs rhs

  let join l1 l2 = min l1 l2

  let widen ~prev ~next ~num_iters:_ = join prev next

  let pp = AbstractAddress.pp
end

(* It so happens that the join we want on stacks is this followed by normalization wrt the
   unification found between abstract locations, so it's convenient to define stacks as elements of
   this domain. Do not use the domain operations outside of {!Domain} though as they are mostly
   meaningless on their own. *)
module AliasingDomain = AbstractDomain.Map (Var) (AbstractAddressDomain_JoinIsMin)

type actor = {access_expr: AccessExpression.t; location: Location.t}

let pp_actor f {access_expr; location} =
  F.fprintf f "%a@%a" AccessExpression.pp access_expr Location.pp location


(** Locations known to be invalid for a reason described by an {!actor}. *)
module type InvalidAddressesDomain = sig
  include AbstractDomain.S

  val empty : astate

  val add : AbstractAddress.t -> actor -> astate -> astate

  val get_invalidation : AbstractAddress.t -> astate -> actor option
  (** return [Some actor] if the location was invalid by [actor], [None] if it is valid *)

  val map : (AbstractAddress.t -> AbstractAddress.t) -> astate -> astate
  (** translate invalid addresses according to the mapping *)
end

module InvalidAddressesDomain : InvalidAddressesDomain = struct
  module InvalidationReason = struct
    type astate = actor

    let join actor _ = actor

    (* actors do not participate in the comparison of sets of invalid locations *)
    let ( <= ) ~lhs:_ ~rhs:_ = true

    let widen ~prev ~next:_ ~num_iters:_ = prev

    let pp = pp_actor
  end

  include AbstractDomain.Map (AbstractAddress) (InvalidationReason)

  let get_invalidation address invalids = find_opt address invalids

  let map f invalids = fold (fun key actor invalids -> add (f key) actor invalids) invalids empty
end

type t = {heap: Memory.t; stack: AliasingDomain.astate; invalids: InvalidAddressesDomain.astate}

let initial =
  {heap= Memory.empty; stack= AliasingDomain.empty; invalids= InvalidAddressesDomain.empty}


module Domain : AbstractDomain.S with type astate = t = struct
  type astate = t

  let piecewise_lessthan lhs rhs =
    InvalidAddressesDomain.( <= ) ~lhs:lhs.invalids ~rhs:rhs.invalids
    && AliasingDomain.( <= ) ~lhs:lhs.stack ~rhs:rhs.stack
    && Memory.for_all
         (fun addr_src edges ->
           Memory.Edges.for_all
             (fun edge addr_dst ->
               Memory.find_edge_opt addr_src edge rhs.heap
               |> Option.exists ~f:(fun addr -> AbstractAddress.equal addr addr_dst) )
             edges )
         lhs.heap


  module JoinState = struct
    module AddressUnionSet = struct
      module Set = PrettyPrintable.MakePPSet (AbstractAddress)

      type elt = AbstractAddress.t [@@deriving compare]

      type t = Set.t ref

      let create x = ref (Set.singleton x)

      let compare_size _ _ = 0

      let merge ~from ~to_ = to_ := Set.union !from !to_

      let pp f x = Set.pp f !x
    end

    module AddressUF = ImperativeUnionFind.Make (AddressUnionSet)

    (** just to get the correct type coercion *)
    let to_canonical_address subst addr = (AddressUF.find subst addr :> AbstractAddress.t)

    type nonrec t = {subst: AddressUF.t; astate: t}

    (** adds [(src_addr, access, dst_addr)] to [union_heap] and record potential new equality that
       results from it in [subst] *)
    let union_one_edge subst src_addr access dst_addr union_heap =
      let src_addr = to_canonical_address subst src_addr in
      let dst_addr = to_canonical_address subst dst_addr in
      match Memory.find_edge_opt src_addr access union_heap with
      | None ->
          (Memory.add_edge src_addr access dst_addr union_heap, `No_new_equality)
      | Some dst_addr' ->
          (* new equality [dst_addr = dst_addr'] found *)
          ignore (AddressUF.union subst dst_addr dst_addr') ;
          (union_heap, `New_equality)


    module Addresses = Caml.Set.Make (AbstractAddress)

    let rec visit_address subst visited heap addr union_heap =
      if Addresses.mem addr visited then (visited, union_heap)
      else
        let visited = Addresses.add addr visited in
        let visit_edge access addr_dst (visited, union_heap) =
          union_one_edge subst addr access addr_dst union_heap
          |> fst
          |> visit_address subst visited heap addr_dst
        in
        Memory.find_opt addr heap
        |> Option.fold ~init:(visited, union_heap) ~f:(fun visited_union_heap edges ->
               Memory.Edges.fold visit_edge edges visited_union_heap )


    let visit_stack subst heap stack union_heap =
      (* start graph exploration *)
      let visited = Addresses.empty in
      let _, union_heap =
        AliasingDomain.fold
          (fun _var addr (visited, union_heap) -> visit_address subst visited heap addr union_heap)
          stack (visited, union_heap)
      in
      union_heap


    let populate_subst_from_stacks subst stack1 stack2 =
      ignore
        ((* Use [Caml.Map.merge] to detect the variables present in both stacks. Build an empty
            result map since we don't use the result. *)
         AliasingDomain.merge
           (fun _var addr1_opt addr2_opt ->
             Option.both addr1_opt addr2_opt
             |> Option.iter ~f:(fun (addr1, addr2) ->
                    (* stack1 says [_var = addr1] and stack2 says [_var = addr2]: unify the
                       addresses since they are equal to the same variable *)
                    ignore (AddressUF.union subst addr1 addr2) ) ;
             (* empty result map *)
             None )
           stack1 stack2)


    let from_astate_union {heap= heap1; stack= stack1; invalids= invalids1}
        {heap= heap2; stack= stack2; invalids= invalids2} =
      let subst = AddressUF.create () in
      (* gather equalities from the stacks *)
      populate_subst_from_stacks subst stack1 stack2 ;
      (* union the heaps, take this opportunity to do garbage collection of unreachable values by
         only copying the addresses reachable from the variables in the stacks *)
      let heap = visit_stack subst heap1 stack1 Memory.empty |> visit_stack subst heap2 stack2 in
      (* This keeps all the variables and picks one representative address for each variable in
         common thanks to [AbstractAddressDomain_JoinIsMin] *)
      let stack = AliasingDomain.join stack1 stack2 in
      (* basically union *)
      let invalids = InvalidAddressesDomain.join invalids1 invalids2 in
      {subst; astate= {heap; stack; invalids}}


    let rec normalize state =
      let one_addr subst addr edges heap_has_converged =
        Memory.Edges.fold
          (fun access addr_dest (heap, has_converged) ->
            match union_one_edge subst addr access addr_dest heap with
            | heap, `No_new_equality ->
                (heap, has_converged)
            | heap, `New_equality ->
                (heap, false) )
          edges heap_has_converged
      in
      let heap, has_converged =
        Memory.fold (one_addr state.subst) state.astate.heap (Memory.empty, true)
      in
      if has_converged then (
        L.d_strln "Join unified addresses:" ;
        L.d_increase_indent 1 ;
        Container.iter state.subst ~fold:AddressUF.fold_sets
          ~f:(fun ((repr : AddressUF.Repr.t), set) ->
            L.d_strln
              (F.asprintf "%a=%a" AbstractAddress.pp
                 (repr :> AbstractAddress.t)
                 AddressUnionSet.pp set) ) ;
        L.d_decrease_indent 1 ;
        let stack = AliasingDomain.map (to_canonical_address state.subst) state.astate.stack in
        let invalids =
          InvalidAddressesDomain.map (to_canonical_address state.subst) state.astate.invalids
        in
        {heap; stack; invalids} )
      else normalize {state with astate= {state.astate with heap}}
  end

  (** Given

      - stacks S1, S2 : Var -> Address,

      - graphs G1, G2 : Address -> Access -> Address,

      - and invalid sets I1, I2 : 2^Address

      (all finite), the join of 2 abstract states (S1, G1, I1) and (S2, G2, I2) is (S, G, A) where
      there exists a substitution σ from addresses to addresses such that the following holds. Given
      addresses l, l', access path a, and graph G, we write l –a–> l' ∈ G if there is a path labelled
      by a from l to l' in G (in particular, if a is empty then l –a–> l' ∈ G for all l, l').

      ∀ i ∈ {1,2}, ∀ l, x, a, ∀ l' ∈ Ii, ((x, l) ∈ Si ∧ l –a–> l' ∈ Gi)
                                         => (x, σ(l)) ∈ S ∧ σ(l) –a–> σ(l') ∈ G ∧ σ(l') ∈ I

      For now the implementation gives back a larger heap than necessary, where all the previously
      reachable location are still reachable (up to the substitution) instead of only the locations
      leading to invalid ones.
  *)
  let join astate1 astate2 =
    if phys_equal astate1 astate2 then astate1
    else
      (* high-level idea: maintain some union-find data structure to identify locations in one heap
         with locations in the other heap. Build the initial join state as follows:

         - equate all locations that correspond to identical variables in both stacks, eg joining
         stacks {x=1} and {x=2} adds "1=2" to the unification.

         - add all addresses reachable from stack variables to the join state heap

         This gives us an abstract state that is the union of both abstract states, but more states
         can still be made equal. For instance, if 1 points to 3 in the first heap and 2 points to 4
         in the second heap and we deduced "1 = 2" from the stacks already (as in the example just
         above) then we can deduce "3 = 4". Proceed in this fashion until no more equalities are
         discovered, and return the abstract state where a canonical representative has been chosen
         consistently for each equivalence class (this is what the union-find data structure gives
         us). *)
      JoinState.from_astate_union astate1 astate2 |> JoinState.normalize


  (* TODO: this could be [piecewise_lessthan lhs' (join lhs rhs)] where [lhs'] is [lhs] renamed
     according to the unification discovered while joining [lhs] and [rhs]. *)
  let ( <= ) ~lhs ~rhs = phys_equal lhs rhs || piecewise_lessthan lhs rhs

  let max_widening = 5

  let widen ~prev ~next ~num_iters =
    (* widening is underapproximation for now... TODO *)
    if num_iters > max_widening then prev
    else if phys_equal prev next then prev
    else join prev next


  let pp fmt {heap; stack; invalids} =
    F.fprintf fmt "{@[<v1> heap=@[<hv>%a@];@;stack=@[<hv>%a@];@;invalids=@[<hv>%a@];@]}" Memory.pp
      heap AliasingDomain.pp stack InvalidAddressesDomain.pp invalids
end

(* {2 Access operations on the domain} *)

module Diagnostic = struct
  type t =
    | AccessToInvalidAddress of
        { invalidated_at: actor
        ; accessed_by: actor
        ; address: AbstractAddress.t }

  let get_location (AccessToInvalidAddress {accessed_by= {location}}) = location

  let get_message (AccessToInvalidAddress {accessed_by; invalidated_at; address}) =
    let pp_debug_address f =
      if Config.debug_mode then F.fprintf f " (debug: %a)" AbstractAddress.pp address
    in
    F.asprintf "`%a` accesses address `%a` past its lifetime%t" AccessExpression.pp
      accessed_by.access_expr AccessExpression.pp invalidated_at.access_expr pp_debug_address


  let get_trace (AccessToInvalidAddress {accessed_by; invalidated_at}) =
    [ Errlog.make_trace_element 0 invalidated_at.location
        (F.asprintf "invalidated `%a` here" AccessExpression.pp invalidated_at.access_expr)
        []
    ; Errlog.make_trace_element 0 accessed_by.location
        (F.asprintf "accessed `%a` here" AccessExpression.pp accessed_by.access_expr)
        [] ]


  let get_issue_type (AccessToInvalidAddress _) = IssueType.use_after_lifetime
end

type 'a access_result = ('a, Diagnostic.t) result

(** Check that the address is not known to be invalid *)
let check_addr_access actor address astate =
  match InvalidAddressesDomain.get_invalidation address astate.invalids with
  | Some invalidated_at ->
      Error (Diagnostic.AccessToInvalidAddress {invalidated_at; accessed_by= actor; address})
  | None ->
      Ok astate


(** Walk the heap starting from [addr] and following [path]. Stop either at the element before last
   and return [new_addr] if [overwrite_last] is [Some new_addr], or go until the end of the path if it
   is [None]. Create more addresses into the heap as needed to follow the [path]. Check that each
   address reached is valid. *)
let rec walk actor ~overwrite_last addr path astate =
  match (path, overwrite_last) with
  | [], None ->
      Ok (astate, addr)
  | [], Some _ ->
      L.die InternalError "Cannot overwrite last address in empty path"
  | [a], Some new_addr ->
      check_addr_access actor addr astate
      >>| fun astate ->
      let heap = Memory.add_edge addr a new_addr astate.heap in
      ({astate with heap}, new_addr)
  | a :: path, _ -> (
      check_addr_access actor addr astate
      >>= fun astate ->
      match Memory.find_edge_opt addr a astate.heap with
      | None ->
          let addr' = AbstractAddress.mk_fresh () in
          let heap = Memory.add_edge addr a addr' astate.heap in
          let astate = {astate with heap} in
          walk actor ~overwrite_last addr' path astate
      | Some addr' ->
          walk actor ~overwrite_last addr' path astate )


(** add addresses to the state to give a address to the destination of the given access path *)
let walk_access_expr ?overwrite_last astate access_expr location =
  let (access_var, _), access_list = AccessExpression.to_access_path access_expr in
  match (overwrite_last, access_list) with
  | Some new_addr, [] ->
      let stack = AliasingDomain.add access_var new_addr astate.stack in
      Ok ({astate with stack}, new_addr)
  | None, _ | Some _, _ :: _ ->
      let astate, base_addr =
        match AliasingDomain.find_opt access_var astate.stack with
        | Some addr ->
            (astate, addr)
        | None ->
            let addr = AbstractAddress.mk_fresh () in
            let stack = AliasingDomain.add access_var addr astate.stack in
            ({astate with stack}, addr)
      in
      let actor = {access_expr; location} in
      walk actor ~overwrite_last base_addr access_list astate


(** Use the stack and heap to walk the access path represented by the given expression down to an
    abstract address representing what the expression points to.

    Return an error state if it traverses some known invalid address or if the end destination is
    known to be invalid. *)
let materialize_address astate access_expr = walk_access_expr astate access_expr

(** Use the stack and heap to walk the access path represented by the given expression down to an
    abstract address representing what the expression points to, and replace that with the given
    address.

    Return an error state if it traverses some known invalid address. *)
let overwrite_address astate access_expr new_addr =
  walk_access_expr ~overwrite_last:new_addr astate access_expr


(** Add the given address to the set of know invalid addresses. *)
let mark_invalid actor address astate =
  {astate with invalids= InvalidAddressesDomain.add address actor astate.invalids}


let read location access_expr astate =
  materialize_address astate access_expr location
  >>= fun (astate, addr) ->
  let actor = {access_expr; location} in
  check_addr_access actor addr astate >>| fun astate -> (astate, addr)


let read_all location access_exprs astate =
  List.fold_result access_exprs ~init:astate ~f:(fun astate access_expr ->
      read location access_expr astate >>| fst )


let write location access_expr addr astate =
  overwrite_address astate access_expr addr location >>| fun (astate, _) -> astate


let havoc var astate = {astate with stack= AliasingDomain.remove var astate.stack}

let invalidate location access_expr astate =
  materialize_address astate access_expr location
  >>= fun (astate, addr) ->
  let actor = {access_expr; location} in
  check_addr_access actor addr astate >>| mark_invalid actor addr


include Domain

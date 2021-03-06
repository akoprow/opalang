(*
    Copyright © 2011 MLstate

    This file is part of OPA.

    OPA is free software: you can redistribute it and/or modify it under the
    terms of the GNU Affero General Public License, version 3, as published by
    the Free Software Foundation.

    OPA is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for
    more details.

    You should have received a copy of the GNU Affero General Public License
    along with OPA. If not, see <http://www.gnu.org/licenses/>.
*)
(*
    @author Raja Boujbel
    @author Louis Gesbert
**)

open Cps.Ops
module D = Badop.Dialog
module N = Badop_structure.Node_property
module Data = Badop.Data
module Key = Badop_structure.Key
module Path = Badop_structure.Path

module F (Bk: Badop.S) = struct
  type database = Bk.database
  type transaction = Bk.transaction
  type revision = Bk.revision

  let node_config = ref []

  let open_database options k = Bk.open_database options @> k
  let close_database db k = Bk.close_database db @> k
  let status db k = Bk.status db @> fun st -> Badop.Layer("Check", st) |> k


  module Tr = struct
    let start db errk k = Bk.Tr.start db errk @> k
    let start_at_revision db rev errk k = Bk.Tr.start_at_revision db rev errk @> k
    let prepare tr k = Bk.Tr.prepare tr @> k
    let commit tr k = Bk.Tr.commit tr @> k
    let abort tr k = Bk.Tr.abort tr @> k
  end

  type 'which read_op = 'which Bk.read_op
  type 'which write_op = 'which Bk.write_op


  let read tr path read_op k = Bk.read tr path read_op @> k

  let write tr path write_op k =
    (match Path.to_list path with
    | Key.IntKey 2 :: Key.IntKey (-1) :: []
    | Key.IntKey 2 :: Key.IntKey 0 :: [] ->
        () (* we don't check schema writing, because first one can't be checked (empty config) *)
    | _ ->
      (match write_op with
      | Badop.Set (D.Query data) ->
        let nodeconfig = N.get_node_config path !node_config in
        let isok =
        match nodeconfig.N.node_type, data with
        | N.Int   , Data.Int _
        | N.Text  , Data.Text _
        | N.Binary, Data.Binary _
        | N.Unit,   Data.Unit
        | N.Float , Data.Float _ -> true
        | _, _ -> false in
        if not isok then
          (#<If:BADOP_DEBUG>
            Printf.eprintf "Type error : node at %s should be %s, not %s\n%!"
              (Path.to_string path)
              (N.StringOf.node_type nodeconfig.N.node_type)
              (Data.to_string data)
            #<End>;
           assert false);
      | _ -> ()));
    Bk.write tr path write_op @> k


  let write_list trans path_op_list k =
    let wr trans (path, op) k =
      write trans path op (fun resp -> Badop.Aux.result_transaction resp |> k)
    in
    Cps.List.fold wr trans path_op_list k

  let node_properties db config k =
    node_config := config;
    Bk.node_properties db config @> k

  module Debug = struct
    let revision_to_string = Bk.Debug.revision_to_string
  end
end

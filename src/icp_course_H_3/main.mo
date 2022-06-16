import Array "mo:base/Array";
import Error "mo:base/Error";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Debug "mo:base/Debug";
import Blob "mo:base/Blob";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Principal "mo:base/Principal";
import Cycles "mo:base/ExperimentalCycles";

import IC "./ic";
import Types "./types";

actor class cycle_manager(m: Nat, list: [Types.Owner]) = self {
  public type Owner = Types.Owner;
  public type Canister = Types.Canister;
  public type ID = Types.ID;
  public type Proposal = Types.Proposal;
  public type ProposalType = Types.ProposalType;

  var proposals : Buffer.Buffer<Proposal> = Buffer.Buffer<Proposal>(0);
  var ownedCanisters : [Canister] = [];

  // map of ( Canister - Bool), value is true means this canister need multi-sig managed
  var ownedCanisterPermissions : HashMap.HashMap<Canister, Bool> = HashMap.HashMap<Canister, Bool>(0, func(x: Canister,y: Canister) {x==y}, Principal.hash);
  var ownerList : [Owner] = list;

  var M : Nat = m;
  var N : Nat = ownerList.size();

  public query func get_model() : async (Nat, Nat) {
    (M, N)
  };

  public query func get_permission(id: Canister) : async ?Bool {
    ownedCanisterPermissions.get(id)
  };

  public query func get_proposal(id: ID) : async ?Proposal {
    proposals.getOpt(id)
  };

  public shared (msg) func propose(ptype: ProposalType, canister_id: ?Canister, wasm_code: ?Blob) : async Proposal {
    // caller should be one of the owners
    assert(owner_check(msg.caller));

    // only the canister that (permission = false) can add permission
    if (ptype == #addPermission) {
      assert(Option.isSome(canister_id));
      let b = ownedCanisterPermissions.get(Option.unwrap(canister_id));
      assert(Option.isSome(b) and (not Option.unwrap(b)));
    };

    // only the canister that (permission = true) can remove permission
    if (ptype == #removePermission) {
      assert(Option.isSome(canister_id));
      let b = ownedCanisterPermissions.get(Option.unwrap(canister_id));
      assert(Option.isSome(b) and Option.unwrap(b));
    };

    // if (ptype == #installCode) {
    //   assert(Option.isSome(wasm_code));
    // };

    if (ptype != #createCanister) {
      assert(Option.isSome(canister_id));
    };

    switch (canister_id) {
      case (?id) assert(canister_check(id));
      case (null) {};
    };

    let proposal : Proposal = {
      id = proposals.size();
      wasm_code;
      ptype;
      proposer = msg.caller;
      canister_id;
      approvers = [];
      refusers = [];
      finished = false;
    };

    Debug.print(debug_show(msg.caller, "PROPOSED", proposal.ptype, "Proposal ID", proposal.id));
    Debug.print(debug_show());

    proposals.add(proposal);

    proposal
  };

  public shared (msg) func refuse(id: ID) : async Proposal {
    // caller should be one of the owners
    assert(owner_check(msg.caller));

    assert(id + 1 <= proposals.size());

    var proposal = proposals.get(id);

    assert(not proposal.finished);

    assert(Option.isNull(Array.find(proposal.refusers, func(a: Owner) : Bool { a == msg.caller})));

    proposal := Types.add_refuser(proposal, msg.caller);

    if (proposal.refusers.size() + M > N) {
      proposal := Types.finish_proposer(proposal);
    };

    Debug.print(debug_show(msg.caller, "REFUSED", proposal.ptype, "Proposal ID", proposal.id, "Executed", proposal.finished));
    Debug.print(debug_show());

    proposals.put(id, proposal);
    proposals.get(id)
  };

  public shared (msg) func approve(id: ID) : async Proposal {
    // caller should be one of the owners
    assert(owner_check(msg.caller));

    assert(id + 1 <= proposals.size());

    var proposal = proposals.get(id);

    assert(not proposal.finished);

    assert(Option.isNull(Array.find(proposal.approvers, func(a: Owner) : Bool { a == msg.caller})));

    proposal := Types.add_approver(proposal, msg.caller);

    // for permission realted && create canister proposal we need M approve
    if (proposal.approvers.size() == M) {
      let ic : IC.Self = actor("aaaaa-aa");

      switch (proposal.ptype) {
        case (#addPermission) {
          ownedCanisterPermissions.put(Option.unwrap(proposal.canister_id), true);
        };
        case (#removePermission) {
          ownedCanisterPermissions.put(Option.unwrap(proposal.canister_id), false);
        };
        case (#createCanister) {
          let settings : IC.canister_settings = 
          {
            freezing_threshold = null;
            controllers = ?[Principal.fromActor(self)];
            memory_allocation = null;
            compute_allocation = null;
          };

          Cycles.add(1_000_000_000_000);
          let result = await ic.create_canister({settings = ?settings});

          ownedCanisters := Array.append(ownedCanisters, [result.canister_id]);

          ownedCanisterPermissions.put(result.canister_id, true);

          proposal := Types.update_canister_id(proposal, result.canister_id);
        };
      };

      proposal := Types.finish_proposer(proposal);
    };

    Debug.print(debug_show(msg.caller, "APPROVED", proposal.ptype, "Proposal ID", proposal.id, "Executed", proposal.finished));
    Debug.print(debug_show());

    proposals.put(id, proposal);
    proposals.get(id)
  };

  func owner_check(owner : Owner) : Bool {
    Option.isSome(Array.find(ownerList, func (a: Owner) : Bool { Principal.equal(a, owner) }))
  };

  func canister_check(canister : Canister) : Bool {
    Option.isSome(Array.find(ownedCanisters, func (a: Canister) : Bool { Principal.equal(a, canister) }))
  };

  public query func get_owner_list() : async [Owner] {
    ownerList
  };

  public query func get_owned_canisters_list() : async [Canister] {
    ownedCanisters
  };

  // public shared (msg) func init(list : [Owner], m : Nat) : async Nat {
  //   assert(m <= list.size() and m >= 1);

  //   if (ownerList.size() != 0) {
  //     return M
  //   };

  //   ownerList := list;
  //   M := m;
  //   N := list.size();

  //   Debug.print(debug_show("Caller: ", msg.caller, ". Iint with owner list: ", list, "M=", M, "N=", N));

  //   M
  // };
};

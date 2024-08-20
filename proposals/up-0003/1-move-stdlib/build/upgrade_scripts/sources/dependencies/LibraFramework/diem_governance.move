module diem_framework::diem_governance {
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::vector;

    use diem_std::simple_map::{Self, SimpleMap};
    use diem_std::table::{Self, Table};

    use diem_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use diem_framework::event::{Self, EventHandle};
    use diem_framework::governance_proposal::{Self, GovernanceProposal};
    use diem_framework::reconfiguration;
    use diem_framework::stake;
    use diem_framework::system_addresses;
    use diem_framework::timestamp;
    use diem_framework::voting;

    use ol_framework::libra_coin;
    use ol_framework::epoch_boundary;
    use ol_framework::musical_chairs;
    use ol_framework::testnet;

    #[test_only]
    use ol_framework::libra_coin::LibraCoin;
    #[test_only]
    use diem_framework::coin;

    // use diem_std::debug::print;

    /// The specified address already been used to vote on the same proposal
    const EALREADY_VOTED: u64 = 4;
    /// Proposal is not ready to be resolved. Waiting on time or votes
    const EPROPOSAL_NOT_RESOLVABLE_YET: u64 = 6;
    /// The proposal has not been resolved yet
    const EPROPOSAL_NOT_RESOLVED_YET: u64 = 8;
    /// Metadata location cannot be longer than 256 chars
    const EMETADATA_LOCATION_TOO_LONG: u64 = 9;
    /// Metadata hash cannot be longer than 256 chars
    const EMETADATA_HASH_TOO_LONG: u64 = 10;
    /// Account is not authorized to call this function.
    const EUNAUTHORIZED: u64 = 11;
    /// Function cannot be called on Mainnet
    const ENOT_FOR_MAINNET: u64 = 12;

    /// This matches the same enum const in voting. We have to duplicate it as Move doesn't have support for enums yet.
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

    /// Proposal metadata attribute keys.
    const METADATA_LOCATION_KEY: vector<u8> = b"metadata_location";
    const METADATA_HASH_KEY: vector<u8> = b"metadata_hash";

    /// Store the SignerCapabilities of accounts under the on-chain governance's control.
    struct GovernanceResponsbility has key {
        signer_caps: SimpleMap<address, SignerCapability>,
    }

    /// Configurations of the DiemGovernance, set during Genesis and can be updated by the same process offered
    /// by this DiemGovernance module.
    struct GovernanceConfig has key {
        min_voting_threshold: u128,
        voting_duration_secs: u64,
    }

    struct RecordKey has copy, drop, store {
        voter: address,
        proposal_id: u64,
    }

    /// Records to track the proposals each stake pool has been used to vote on.
    struct VotingRecords has key {
        votes: Table<RecordKey, bool>
    }

    /// Used to track which execution script hashes have been approved by governance.
    /// This is required to bypass cases where the execution scripts exceed the size limit imposed by mempool.
    struct ApprovedExecutionHashes has key {
        hashes: SimpleMap<u64, vector<u8>>,
    }

    /// Events generated by interactions with the DiemGovernance module.
    struct GovernanceEvents has key {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        update_config_events: EventHandle<UpdateConfigEvent>,
        vote_events: EventHandle<VoteEvent>,
    }

    /// Event emitted when a proposal is created.
    struct CreateProposalEvent has drop, store {
        proposer: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    /// Event emitted when there's a vote on a proposa;
    struct VoteEvent has drop, store {
        proposal_id: u64,
        voter: address,
        num_votes: u64,
        should_pass: bool,
    }

    /// Event emitted when the governance configs are updated.
    struct UpdateConfigEvent has drop, store {
        min_voting_threshold: u128,
        voting_duration_secs: u64,
    }

    /// Can be called during genesis or by the governance itself.
    /// Stores the signer capability for a given address.
    public fun store_signer_cap(
        diem_framework: &signer,
        signer_address: address,
        signer_cap: SignerCapability,
    ) acquires GovernanceResponsbility {
        system_addresses::assert_diem_framework(diem_framework);
        system_addresses::assert_framework_reserved(signer_address);

        if (!exists<GovernanceResponsbility>(@diem_framework)) {
            move_to(diem_framework, GovernanceResponsbility { signer_caps: simple_map::create<address, SignerCapability>() });
        };

        let signer_caps = &mut borrow_global_mut<GovernanceResponsbility>(@diem_framework).signer_caps;
        simple_map::add(signer_caps, signer_address, signer_cap);
    }

    /// Initializes the state for Diem Governance. Can only be called during Genesis with a signer
    /// for the diem_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        diem_framework: &signer,
        min_voting_threshold: u128,
        _dummy: u64, // TODO: this function is called by diem platform code,
        // and it expects this argument.
        voting_duration_secs: u64,
    ) {
        system_addresses::assert_diem_framework(diem_framework);

        voting::register<GovernanceProposal>(diem_framework);
        move_to(diem_framework, GovernanceConfig {
            voting_duration_secs,
            min_voting_threshold,
        });
        move_to(diem_framework, GovernanceEvents {
            create_proposal_events: account::new_event_handle<CreateProposalEvent>(diem_framework),
            update_config_events: account::new_event_handle<UpdateConfigEvent>(diem_framework),
            vote_events: account::new_event_handle<VoteEvent>(diem_framework),
        });
        move_to(diem_framework, VotingRecords {
            votes: table::new(),
        });
        move_to(diem_framework, ApprovedExecutionHashes {
            hashes: simple_map::create<u64, vector<u8>>(),
        })
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// DiemGovernance.
    public fun update_governance_config(
        diem_framework: &signer,
        min_voting_threshold: u128,
        voting_duration_secs: u64,
    ) acquires GovernanceConfig, GovernanceEvents {
        system_addresses::assert_diem_framework(diem_framework);

        let governance_config = borrow_global_mut<GovernanceConfig>(@diem_framework);
        governance_config.voting_duration_secs = voting_duration_secs;
        governance_config.min_voting_threshold = min_voting_threshold;

        let events = borrow_global_mut<GovernanceEvents>(@diem_framework);
        event::emit_event<UpdateConfigEvent>(
            &mut events.update_config_events,
            UpdateConfigEvent {
                min_voting_threshold,
                voting_duration_secs
            },
        );
    }

    #[view]
    public fun get_voting_duration_secs(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@diem_framework).voting_duration_secs
    }

    #[view]
    public fun get_min_voting_threshold(): u128 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@diem_framework).min_voting_threshold
    }


    /// Create a single-step or multi-step proposal
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal_v2(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ) acquires GovernanceConfig, GovernanceEvents {
        let proposer_address = signer::address_of(proposer);

        let governance_config =
        borrow_global<GovernanceConfig>(@diem_framework);

        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + governance_config.voting_duration_secs;

        // Create and validate proposal metadata.
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

        let proposal_id = voting::create_proposal_v2(
            proposer_address,
            @diem_framework,
            governance_proposal::create_proposal(),
            execution_hash,
            governance_config.min_voting_threshold,
            proposal_expiration,
            option::none(),
            proposal_metadata,
            is_multi_step_proposal,
        );

        let events = borrow_global_mut<GovernanceEvents>(@diem_framework);
        event::emit_event<CreateProposalEvent>(
            &mut events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                proposer: proposer_address,
                execution_hash,
                proposal_metadata,
            },
        );
    }

    /// Create a single-step or multi-step proposal
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun ol_create_proposal_v2(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>, // url
        metadata_hash: vector<u8>, // descriptions etc.
        is_multi_step_proposal: bool,
    ) acquires GovernanceConfig, GovernanceEvents {
        let proposer_address = signer::address_of(proposer);
        assert!(stake::is_current_val(proposer_address), error::invalid_argument(EUNAUTHORIZED));

        // TODO what's this for?
        let _governance_config = borrow_global<GovernanceConfig>(@diem_framework);

        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + (60 * 60 * 24 * 3); // Three days

        // Create and validate proposal metadata.
        // NOTE: 0L: this is a buffer sent from  rust because there is no type
        // that can be sent in an entry transactions. Not clear why it's not implemented as ASCII
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

        // We want to allow early resolution of proposals if more than 50% of the total supply of the network coins
        // has voted. This doesn't take into subsequent inflation/deflation (rewards are issued every epoch and gas fees
        // are burnt after every transaction), but inflation/delation is very unlikely to have a major impact on total
        // supply during the voting period.
        let validator_len = vector::length(&stake::get_current_validators());
        let early_resolution_vote_threshold = ((((validator_len/3) * 2) + 1) as u128);

        let proposal_id = voting::create_proposal_v2(
            proposer_address,
            @diem_framework,
            governance_proposal::create_proposal(),
            execution_hash,
            early_resolution_vote_threshold, // 0L we always expect the minimum of 2/3+1 to pass
            proposal_expiration,
            option::some(early_resolution_vote_threshold), // will end before deadline at this threshold
            proposal_metadata,
            is_multi_step_proposal,
        );

        let events = borrow_global_mut<GovernanceEvents>(@diem_framework);
        event::emit_event<CreateProposalEvent>(
            &mut events.create_proposal_events,
            CreateProposalEvent {
                proposal_id,
                proposer: proposer_address,
                execution_hash,
                proposal_metadata,
            },
        );
    }

    /// Vote on proposal with `proposal_id`.
    public entry fun ol_vote(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, GovernanceEvents, VotingRecords {
        let voter_address = signer::address_of(voter);
        assert!(stake::is_current_val(voter_address), error::invalid_argument(EUNAUTHORIZED));
        // register the vote. Prevent double votes
        // TODO: method to retract.
        let voting_records = borrow_global_mut<VotingRecords>(@diem_framework);
        let record_key = RecordKey {
            voter: voter_address,
            proposal_id,
        };
        assert!(
            !table::contains(&voting_records.votes, record_key),
            error::invalid_argument(EALREADY_VOTED));
        table::add(&mut voting_records.votes, record_key, true);

        let voting_power = 1; // every validator has just one equal vote.
        voting::vote<GovernanceProposal>(
            &governance_proposal::create_empty_proposal(),
            @diem_framework,
            proposal_id,
            voting_power,
            should_pass,
        );

        let events = borrow_global_mut<GovernanceEvents>(@diem_framework);
        event::emit_event<VoteEvent>(
            &mut events.vote_events,
            VoteEvent {
                proposal_id,
                voter: voter_address,
                num_votes: voting_power,
                should_pass,
            },
        );

        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@diem_framework, proposal_id);
        if (proposal_state == PROPOSAL_STATE_SUCCEEDED) {
            add_approved_script_hash(proposal_id);
        }
    }


    /// Vote on proposal with `proposal_id`
    public entry fun vote(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, GovernanceEvents, VotingRecords {
        let voter_address = signer::address_of(voter);

        // Ensure the voter doesn't double vote
        let voting_records = borrow_global_mut<VotingRecords>(@diem_framework);
        let record_key = RecordKey {
            voter: voter_address,
            proposal_id,
        };
        assert!(
            !table::contains(&voting_records.votes, record_key),
            error::invalid_argument(EALREADY_VOTED));
        table::add(&mut voting_records.votes, record_key, true);

        let voting_power = libra_coin::balance(voter_address);
        voting::vote<GovernanceProposal>(
            &governance_proposal::create_empty_proposal(),
            @diem_framework,
            proposal_id,
            voting_power,
            should_pass,
        );

        let events = borrow_global_mut<GovernanceEvents>(@diem_framework);
        event::emit_event<VoteEvent>(
            &mut events.vote_events,
            VoteEvent {
                proposal_id,
                voter: voter_address,
                num_votes: voting_power,
                should_pass,
            },
        );

        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@diem_framework, proposal_id);
        if (proposal_state == PROPOSAL_STATE_SUCCEEDED) {
            add_approved_script_hash(proposal_id);
        }
    }

    public entry fun add_approved_script_hash_script(proposal_id: u64) acquires ApprovedExecutionHashes {
        add_approved_script_hash(proposal_id)
    }


    /// Add the execution script hash of a successful governance proposal to the approved list.
    /// This is needed to bypass the mempool transaction size limit for approved governance proposal transactions that
    /// are too large (e.g. module upgrades).
    fun add_approved_script_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@diem_framework);
        // Ensure the proposal can be resolved.
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@diem_framework, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

        let execution_hash = voting::get_execution_hash<GovernanceProposal>(@diem_framework, proposal_id);

        // If this is a multi-step proposal, the proposal id will already exist in the ApprovedExecutionHashes map.
        // We will update execution hash in ApprovedExecutionHashes to be the next_execution_hash.
        if (simple_map::contains_key(&approved_hashes.hashes, &proposal_id)) {
            let current_execution_hash = simple_map::borrow_mut(&mut approved_hashes.hashes, &proposal_id);
            *current_execution_hash = execution_hash;
        } else {
            simple_map::add(&mut approved_hashes.hashes, proposal_id, execution_hash);
        }
    }

    /// Resolve a successful single-step proposal. This would fail if the proposal is not successful (not enough votes or more no
    /// than yes).
    public fun resolve(proposal_id: u64, signer_address: address): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        voting::resolve<GovernanceProposal>(@diem_framework, proposal_id);
        remove_approved_hash(proposal_id);
        get_signer(signer_address)
    }

    #[view]
    // is the proposal complete and executed?
    public fun is_resolved(proposal_id: u64): bool {
      voting::is_resolved<GovernanceProposal>(@diem_framework, proposal_id)
    }

    #[view]
    // is the proposal complete and executed?
    public fun get_votes(proposal_id: u64): (u128, u128) {
      voting::get_votes<GovernanceProposal>(@diem_framework, proposal_id)
    }

    #[view]
    /// what is the state of the proposal
    public fun get_proposal_state(proposal_id: u64):u64  {
      voting::get_proposal_state<GovernanceProposal>(@diem_framework, proposal_id)
    }


    //////// 0L ////////
    // hack for smoke testing:
    // is the proposal approved and ready for resolution?
    public entry fun assert_can_resolve(proposal_id: u64) {
      assert!(get_can_resolve(proposal_id), error::invalid_state(EPROPOSAL_NOT_RESOLVABLE_YET));
    }

    #[view]
    // is the proposal approved and ready for resolution?
    public fun get_can_resolve(proposal_id: u64): bool {
      let (can, _) = voting::check_resolvable_ex_hash<GovernanceProposal>(@diem_framework, proposal_id);
      can
    }

    /// Resolve a successful multi-step proposal. This would fail if the proposal is not successful.
    public fun resolve_multi_step_proposal(proposal_id: u64, signer_address: address, next_execution_hash: vector<u8>): signer acquires GovernanceResponsbility, ApprovedExecutionHashes {
        voting::resolve_proposal_v2<GovernanceProposal>(@diem_framework, proposal_id, next_execution_hash);
        // If the current step is the last step of this multi-step proposal,
        // we will remove the execution hash from the ApprovedExecutionHashes map.
        if (vector::length(&next_execution_hash) == 0) {
            remove_approved_hash(proposal_id);
        } else {
            // If the current step is not the last step of this proposal,
            // we replace the current execution hash with the next execution hash
            // in the ApprovedExecutionHashes map.
            add_approved_script_hash(proposal_id)
        };
        get_signer(signer_address)
    }

    /// Remove an approved proposal's execution script hash.
    public fun remove_approved_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        assert!(
            voting::is_resolved<GovernanceProposal>(@diem_framework, proposal_id),
            error::invalid_argument(EPROPOSAL_NOT_RESOLVED_YET),
        );

        let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@diem_framework).hashes;
        if (simple_map::contains_key(approved_hashes, &proposal_id)) {
            simple_map::remove(approved_hashes, &proposal_id);
        };
    }

    #[view]
    /// we want to check what hash is expected for this upgrade
    public fun get_approved_hash(proposal_id: u64): vector<u8> acquires ApprovedExecutionHashes {
      let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@diem_framework).hashes;
        if (simple_map::contains_key(approved_hashes, &proposal_id)) {
          return *simple_map::borrow(approved_hashes, &proposal_id)
        };
        vector::empty()
    }

    /// Set validators. Pass through gating function. This is needed because stake.move only allows
    // reconfiguration calls from `friend` modules
    public fun set_validators(diem_framework: &signer, new_vals: vector<address>) {
        system_addresses::assert_diem_framework(diem_framework);
        stake::maybe_reconfigure(diem_framework, new_vals);
        // set the musical chairs length, otherwise the musical chairs
        // would not know the set size changed.
        musical_chairs::set_current_seats(diem_framework, vector::length(&new_vals));
    }

    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun reconfigure(diem_framework: &signer) {
        system_addresses::assert_diem_framework(diem_framework);
        reconfiguration::reconfigure();
    }

    // TODO: from v5 evaluate if this is needed or is obviated by
    // block::emit_writeset_block_event, which updates the timestamp.
    /// Force reconfigure and ignore epoch timestamp checking. This is in
    /// and extreme edge condition where an offchain rescue needs to happen
    /// at round 0 of a new epoch, and we have no way to break out of the
    /// reconfiguration timestamp checking
    public fun danger_reconfigure_on_rescue(diem_framework: &signer) {
        system_addresses::assert_diem_framework(diem_framework);
        reconfiguration::danger_reconfigure_ignore_timestamp(diem_framework);
    }

    /// Any end user can triger epoch/boundary and reconfiguration
    /// as long as the VM set the BoundaryBit to true.
    /// We do this because we don't want the VM calling complex
    /// logic itself. Any abort would cause a halt.
    /// On the other hand, a user can call the function once the VM
    /// decides the epoch can change. Any error will just cause the
    /// user's transaction to abort, but the chain will continue.
    /// Whatever fix is needed can be done online with on-chain governance.
    public entry fun trigger_epoch(_sig: &signer) acquires
    GovernanceResponsbility { // doesn't need a signer
      let _ = epoch_boundary::can_trigger(); // will abort if false
      let framework_signer = get_signer(@ol_framework);
      epoch_boundary::trigger_epoch(&framework_signer);
    }

    // helper to use on smoke tests only. Will fail on Mainnet. Needs testnet
    // Core Resources user.
    public entry fun smoke_trigger_epoch(core_resources: &signer) acquires
    GovernanceResponsbility { // doesn't need a signer
      assert!(testnet::is_not_mainnet(), error::invalid_state(ENOT_FOR_MAINNET));
      system_addresses::assert_ol(core_resources);
      let framework_signer = get_signer(@ol_framework);
      epoch_boundary::smoke_trigger_epoch(&framework_signer);
    }

    // COMMIT NOTE: trigger_epoch() should now work on Stage as well.

    // /// Return the voting power
    // fun get_voting_power(_pool_address: address): u64 {
    //     1
    // }

    #[view]
    public fun get_next_governance_proposal_id():u64 {
      voting::get_next_proposal_id<GovernanceProposal>(@diem_framework)
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    fun get_signer(signer_address: address): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@diem_framework);
        let signer_cap = simple_map::borrow(&governance_responsibility.signer_caps, &signer_address);
        create_signer_with_capability(signer_cap)
    }

    fun create_proposal_metadata(metadata_location: vector<u8>, metadata_hash: vector<u8>): SimpleMap<String, vector<u8>> {
        assert!(string::length(&utf8(metadata_location)) <= 256, error::invalid_argument(EMETADATA_LOCATION_TOO_LONG));
        assert!(string::length(&utf8(metadata_hash)) <= 256, error::invalid_argument(EMETADATA_HASH_TOO_LONG));

        let metadata = simple_map::create<String, vector<u8>>();
        simple_map::add(&mut metadata, utf8(METADATA_LOCATION_KEY), metadata_location);
        simple_map::add(&mut metadata, utf8(METADATA_HASH_KEY), metadata_hash);
        metadata
    }

    #[test_only]
    public entry fun create_proposal_for_test(proposer: signer, multi_step:bool) acquires GovernanceConfig, GovernanceEvents {
        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);

        if (multi_step) {
            create_proposal_v2(
                &proposer,
                execution_hash,
                b"",
                b"",
                true,
            );
        } else {
            create_proposal_v2(
                &proposer,
                execution_hash,
                b"",
                b"",
                false,
            );
        };
    }

    #[test_only]
    public entry fun resolve_proposal_for_test(proposal_id: u64, signer_address: address, multi_step: bool, finish_multi_step_execution: bool): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            vector::push_back(&mut execution_hash, 1);

            if (finish_multi_step_execution) {
                resolve_multi_step_proposal(proposal_id, signer_address, vector::empty<u8>())
            } else {
                resolve_multi_step_proposal(proposal_id, signer_address, execution_hash)
            }
        } else {
            resolve(proposal_id, signer_address)
        }
    }

    #[test_only]
    public entry fun test_voting_generic(
        diem_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
        multi_step: bool,
        use_generic_resolve_function: bool,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        setup_voting(&diem_framework, &proposer, &yes_voter, &no_voter);

        let execution_hash = vector::empty<u8>();
        vector::push_back(&mut execution_hash, 1);

        create_proposal_for_test(proposer, multi_step);

        vote(&yes_voter, 0, true); //////// 0L ////////
        vote(&no_voter, 0, false);  //////// 0L ////////

        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(signer::address_of(&diem_framework), 0);
        // let (yes, no) = voting::get_votes<GovernanceProposal>(signer::address_of(&diem_framework), 0);

        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // Add approved script hash.
        add_approved_script_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@diem_framework).hashes;
        assert!(*simple_map::borrow(&approved_hashes, &0) == execution_hash, 0);

        // Resolve the proposal.
        let account = resolve_proposal_for_test(0, @diem_framework, use_generic_resolve_function, true);
        assert!(signer::address_of(&account) == @diem_framework, 1);
        assert!(voting::is_resolved<GovernanceProposal>(@diem_framework, 0), 2);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@diem_framework).hashes;
        assert!(!simple_map::contains_key(&approved_hashes, &0), 3);
    }

    #[test(diem_framework = @diem_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        diem_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceEvents, GovernanceResponsbility, VotingRecords {
        test_voting_generic(diem_framework, proposer, yes_voter, no_voter, false, false);
    }


    #[test_only]
    //////// 0L //////// remove minimum threshold
    public fun initialize_for_test(root: &signer) {
      system_addresses::assert_ol(root);

      let min_voting_threshold = 0;
      let dummy = 0; // see code, requires refactor
      let voting_duration_secs = 100000000000;


      initialize(root, min_voting_threshold, dummy, voting_duration_secs);
    }

    #[test_only]
    public fun setup_voting(
        diem_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        // use std::vector;
        use diem_framework::account;
        // use diem_framework::coin;
        // use diem_framework::diem_coin::{Self, DiemCoin};

        timestamp::set_time_has_started_for_testing(diem_framework);
        account::create_account_for_test(signer::address_of(diem_framework));
        account::create_account_for_test(signer::address_of(proposer));
        account::create_account_for_test(signer::address_of(yes_voter));
        account::create_account_for_test(signer::address_of(no_voter));

        // Initialize the governance.
        let min_voting_threshold = 0;
        let dummy = 0; // see code, requires refactor
        let voting_duration = 1000;
        initialize(diem_framework, min_voting_threshold, dummy, voting_duration);
        store_signer_cap(
            diem_framework,
            @diem_framework,
            account::create_test_signer_cap(@diem_framework),
        );

        let (burn_cap, mint_cap) = libra_coin::initialize_for_test(diem_framework);
        coin::register<LibraCoin>(proposer);
        coin::register<LibraCoin>(yes_voter);
        coin::register<LibraCoin>(no_voter);

        libra_coin::test_mint_to(diem_framework, signer::address_of(proposer), 50);
        libra_coin::test_mint_to(diem_framework, signer::address_of(yes_voter), 10);
        libra_coin::test_mint_to(diem_framework, signer::address_of(no_voter), 5);

        coin::destroy_mint_cap<LibraCoin>(mint_cap);
        coin::destroy_burn_cap<LibraCoin>(burn_cap);
    }

    #[verify_only]
    public fun initialize_for_verification(
        diem_framework: &signer,
        min_voting_threshold: u128,
        voting_duration_secs: u64,
    ) {
        initialize(diem_framework, min_voting_threshold, 0, voting_duration_secs);
    }
}
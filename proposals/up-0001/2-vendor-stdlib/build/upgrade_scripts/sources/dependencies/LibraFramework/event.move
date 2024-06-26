/// The Event module defines an `EventHandleGenerator` that is used to create
/// `EventHandle`s with unique GUIDs. It contains a counter for the number
/// of `EventHandle`s it generates. An `EventHandle` is used to count the number of
/// events emitted to a handle and emit events to the event store.
module diem_framework::event {
    use std::bcs;

    use diem_framework::guid::GUID;

    friend diem_framework::account;
    friend diem_framework::object;
    //////// 0L ////////
    friend diem_framework::voting;
    friend diem_framework::stake;
    friend diem_framework::multisig_account;
    friend diem_framework::fungible_asset;
    friend diem_framework::diem_governance;
    friend diem_framework::coin;
    friend diem_framework::block;

    friend ol_framework::slow_wallet;
    friend ol_framework::reconfiguration;
    friend ol_framework::ol_account;

    #[test_only]
    friend diem_framework::diem_account;
    #[test_only]
    friend diem_framework::demo;
    //////// end 0L ////////

    /// A handle for an event such that:
    /// 1. Other modules can emit events to this handle.
    /// 2. Storage can use this handle to prove the total number of events that happened in the past.
    struct EventHandle<phantom T: drop + store> has store, drop { // HARD FORK, reverse the `drop` here
        /// Total number of events emitted to this event stream.
        counter: u64,
        /// A globally unique ID for this event stream.
        guid: GUID,
    }

    /// Use EventHandleGenerator to generate a unique event handle for `sig`
    public(friend) fun new_event_handle<T: drop + store>(guid: GUID): EventHandle<T> {
        EventHandle<T> {
            counter: 0,
            guid,
        }
    }

    /// Emit an event with payload `msg` by using `handle_ref`'s key and counter.
    public(friend) fun emit_event<T: drop + store>(handle_ref: &mut EventHandle<T>, msg: T) {
        write_to_event_store<T>(bcs::to_bytes(&handle_ref.guid), handle_ref.counter, msg);
        spec {
            assume handle_ref.counter + 1 <= MAX_U64;
        };
        handle_ref.counter = handle_ref.counter + 1;
    }

    /// Return the GUID associated with this EventHandle
    public(friend) fun guid<T: drop + store>(handle_ref: &EventHandle<T>): &GUID {
        &handle_ref.guid
    }

    /// Return the current counter associated with this EventHandle
    public(friend) fun counter<T: drop + store>(handle_ref: &EventHandle<T>): u64 {
        handle_ref.counter
    }

    /// Log `msg` as the `count`th event associated with the event stream identified by `guid`
    native fun write_to_event_store<T: drop + store>(guid: vector<u8>, count: u64, msg: T);

    /// Destroy a unique handle.
    public(friend) fun destroy_handle<T: drop + store>(handle: EventHandle<T>) {
        EventHandle<T> { counter: _, guid: _ } = handle;
    }
}

/// This module provides the foundation for typesafe Coins.
module diem_framework::coin {
    use std::string;
    use std::error;
    use std::option::{Self, Option};
    use std::signer;

    use diem_framework::account::{Self, WithdrawCapability};
    use diem_framework::aggregator_factory;
    use diem_framework::aggregator::{Self, Aggregator};
    use diem_framework::event::{Self, EventHandle};
    use diem_framework::optional_aggregator::{Self, OptionalAggregator};
    use diem_framework::system_addresses;

    use diem_std::type_info;
    use diem_std::math128;


    friend ol_framework::libra_coin;
    friend ol_framework::burn;
    friend ol_framework::ol_account;
    friend diem_framework::genesis;
    friend diem_framework::genesis_migration;
    friend diem_framework::transaction_fee;
    friend diem_framework::transaction_validation;


    // NOTE: these vendor structs are left here for tests
    // which use those structs
    #[test_only]
    friend diem_framework::diem_coin;
    #[test_only]
    friend diem_framework::diem_account;
    #[test_only]
    friend diem_framework::resource_account;
    #[test_only]
    friend diem_framework::diem_governance;
    #[test_only]
    friend ol_framework::test_account;
    #[test_only]
    friend ol_framework::mock;
    #[test_only]
    friend ol_framework::test_slow_wallet;
    #[test_only]
    friend ol_framework::test_burn;
    #[test_only]
    friend ol_framework::test_rewards;


    //
    // Errors.
    //

    /// Address of account which is used to initialize a coin `CoinType` doesn't match the deployer of module
    const ECOIN_INFO_ADDRESS_MISMATCH: u64 = 1;

    /// `CoinType` is already initialized as a coin
    const ECOIN_INFO_ALREADY_PUBLISHED: u64 = 2;

    /// `CoinType` hasn't been initialized as a coin
    const ECOIN_INFO_NOT_PUBLISHED: u64 = 3;

    /// Deprecated. Account already has `CoinStore` registered for `CoinType`
    const ECOIN_STORE_ALREADY_PUBLISHED: u64 = 4;

    /// Account hasn't registered `CoinStore` for `CoinType`
    const ECOIN_STORE_NOT_PUBLISHED: u64 = 5;

    /// Not enough coins to complete transaction
    const EINSUFFICIENT_BALANCE: u64 = 6;

    /// Cannot destroy non-zero coins
    const EDESTRUCTION_OF_NONZERO_TOKEN: u64 = 7;

    /// Coin amount cannot be zero
    const EZERO_COIN_AMOUNT: u64 = 9;

    /// CoinStore is frozen. Coins cannot be deposited or withdrawn
    const EFROZEN: u64 = 10;

    /// Cannot upgrade the total supply of coins to different implementation.
    const ECOIN_SUPPLY_UPGRADE_NOT_SUPPORTED: u64 = 11;

    /// Name of the coin is too long
    const ECOIN_NAME_TOO_LONG: u64 = 12;

    /// Symbol of the coin is too long
    const ECOIN_SYMBOL_TOO_LONG: u64 = 13;

    /// The value of aggregatable coin used for transaction fees redistribution does not fit in u64.
    const EAGGREGATABLE_COIN_VALUE_TOO_LARGE: u64 = 14;

    //
    // Constants
    //

    const MAX_COIN_NAME_LENGTH: u64 = 32;
    const MAX_COIN_SYMBOL_LENGTH: u64 = 10;

    /// Core data structures

    /// Main structure representing a coin/token in an account's custody.
    struct Coin<phantom CoinType> has store {
        /// Amount of coin this address has.
        value: u64,
    }

    /// Represents a coin with aggregator as its value. This allows to update
    /// the coin in every transaction avoiding read-modify-write conflicts. Only
    /// used for gas fees distribution by Diem Framework (0x1).
    struct AggregatableCoin<phantom CoinType> has store {
        /// Amount of aggregatable coin this address has.
        value: Aggregator,
    }

    /// Maximum possible aggregatable coin value.
    const MAX_U64: u128 = 18446744073709551615;

    /// A holder of a specific coin types and associated event handles.
    /// These are kept in a single resource to ensure locality of data.
    struct CoinStore<phantom CoinType> has key {
        coin: Coin<CoinType>,
        deposit_events: EventHandle<DepositEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
    }

    /// Maximum possible coin supply.
    const MAX_U128: u128 = 340282366920938463463374607431768211455;

    /// Configuration that controls the behavior of total coin supply. If the field
    /// is set, coin creators are allowed to upgrade to parallelizable implementations.
    struct SupplyConfig has key {
        allow_upgrades: bool,
    }

    /// Information about a specific coin type. Stored on the creator of the coin's account.
    struct CoinInfo<phantom CoinType> has key {
        name: string::String,
        /// Symbol of the coin, usually a shorter version of the name.
        /// For example, Singapore Dollar is SGD.
        symbol: string::String,
        /// Number of decimals used to get its user representation.
        /// For example, if `decimals` equals `2`, a balance of `505` coins should
        /// be displayed to a user as `5.05` (`505 / 10 ** 2`).
        decimals: u8,
        /// Amount of this coin type in existence.
        supply: Option<OptionalAggregator>,
    }

    /// Event emitted when some amount of a coin is deposited into an account.
    struct DepositEvent has drop, store {
        amount: u64,
    }

    /// Event emitted when some amount of a coin is withdrawn from an account.
    struct WithdrawEvent has drop, store {
        amount: u64,
    }

    /// Capability required to mint coins.
    struct MintCapability<phantom CoinType> has copy, store {}

    /// Capability required to freeze a coin store.
    struct FreezeCapability<phantom CoinType> has copy, store {}

    /// Capability required to burn coins.
    struct BurnCapability<phantom CoinType> has copy, store {}

    //
    // Total supply config
    //

    /// Publishes supply configuration. Initially, upgrading is not allowed.
    public(friend) fun initialize_supply_config(diem_framework: &signer) {
        system_addresses::assert_diem_framework(diem_framework);
        move_to(diem_framework, SupplyConfig { allow_upgrades: false });
    }

    //NOTE(deprecated): no need to upgrade current supply

    //
    //  Aggregatable coin functions
    //

    /// Creates a new aggregatable coin with value overflowing on `limit`. Note that this function can
    /// only be called by Diem Framework (0x1) account for now becuase of `create_aggregator`.
    public(friend) fun initialize_aggregatable_coin<CoinType>(diem_framework: &signer): AggregatableCoin<CoinType> {
        let aggregator = aggregator_factory::create_aggregator(diem_framework, MAX_U64);
        AggregatableCoin<CoinType> {
            value: aggregator,
        }
    }

    //////// 0L ////////
    /// the value of the aggregated coin
    public(friend) fun aggregatable_value<CoinType>(aggregatable_coin: &AggregatableCoin<CoinType>): u128 {
        aggregator::read(&aggregatable_coin.value)
    }

    /// Returns true if the value of aggregatable coin is zero.
    public(friend) fun is_aggregatable_coin_zero<CoinType>(coin: &AggregatableCoin<CoinType>): bool {
        let amount = aggregator::read(&coin.value);
        amount == 0
    }

    /// Drains the aggregatable coin, setting it to zero and returning a standard coin.
    public(friend) fun drain_aggregatable_coin<CoinType>(coin: &mut AggregatableCoin<CoinType>): Coin<CoinType> {
        spec {
            // TODO: The data invariant is not properly assumed from CollectedFeesPerBlock.
            assume aggregator::spec_get_limit(coin.value) == MAX_U64;
        };
        let amount = aggregator::read(&coin.value);
        assert!(amount <= MAX_U64, error::out_of_range(EAGGREGATABLE_COIN_VALUE_TOO_LARGE));

        aggregator::sub(&mut coin.value, amount);
        Coin<CoinType> {
            value: (amount as u64),
        }
    }

    /// Merges `coin` into aggregatable coin (`dst_coin`).
    public(friend) fun merge_aggregatable_coin<CoinType>(dst_coin: &mut AggregatableCoin<CoinType>, coin: Coin<CoinType>) {
        let Coin { value } = coin;
        let amount = (value as u128);
        aggregator::add(&mut dst_coin.value, amount);
    }

    /// Collects a specified amount of coin form an account into aggregatable coin.
    public(friend) fun collect_into_aggregatable_coin<CoinType>(
        account_addr: address,
        amount: u64,
        dst_coin: &mut AggregatableCoin<CoinType>,
    ) acquires CoinStore {
        // Skip collecting if amount is zero.
        if (amount == 0) {
            return
        };

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);
        let coin = extract(&mut coin_store.coin, amount);
        merge_aggregatable_coin(dst_coin, coin);
    }

    //
    // Getter functions
    //

    /// A helper function that returns the address of CoinType.
    fun coin_address<CoinType>(): address {
        let type_info = type_info::type_of<CoinType>();
        type_info::account_address(&type_info)
    }

    /// Returns the balance of `owner` for provided `CoinType`.
    public(friend) fun balance<CoinType>(owner: address): u64 acquires CoinStore {
        // should not abort if the VM might call this
        if (!is_account_registered<CoinType>(owner)) return 0;
        borrow_global<CoinStore<CoinType>>(owner).coin.value
    }



    #[view]
    /// Returns `true` if the type `CoinType` is an initialized coin.
    public fun is_coin_initialized<CoinType>(): bool {
        exists<CoinInfo<CoinType>>(coin_address<CoinType>())
    }

    #[view]
    /// Returns `true` if `account_addr` is registered to receive `CoinType`.
    public fun is_account_registered<CoinType>(account_addr: address): bool {
        exists<CoinStore<CoinType>>(account_addr)
    }

    #[view]
    /// Returns the name of the coin.
    public fun name<CoinType>(): string::String acquires CoinInfo {
        borrow_global<CoinInfo<CoinType>>(coin_address<CoinType>()).name
    }

    #[view]
    /// Returns the symbol of the coin, usually a shorter version of the name.
    public fun symbol<CoinType>(): string::String acquires CoinInfo {
        borrow_global<CoinInfo<CoinType>>(coin_address<CoinType>()).symbol
    }

    #[view]
    /// Returns the number of decimals used to get its user representation.
    /// For example, if `decimals` equals `2`, a balance of `505` coins should
    /// be displayed to a user as `5.05` (`505 / 10 ** 2`).
    public fun decimals<CoinType>(): u8 acquires CoinInfo {
        borrow_global<CoinInfo<CoinType>>(coin_address<CoinType>()).decimals
    }

    #[view]
    /// Returns the amount of coin in existence.
    public fun supply<CoinType>(): Option<u128> acquires CoinInfo {
        let maybe_supply = &borrow_global<CoinInfo<CoinType>>(coin_address<CoinType>()).supply;
        if (option::is_some(maybe_supply)) {
            // We do track supply, in this case read from optional aggregator.
            let supply = option::borrow(maybe_supply);
            let value = optional_aggregator::read(supply);
            option::some(value)
        } else {
            option::none()
        }
    }


    // only public to internal functions
    // users should call burn::burn_and_track
    #[test_only]
    fun test_burn<CoinType>(
        coin: Coin<CoinType>,
        _cap: &BurnCapability<CoinType>,
    ) acquires CoinInfo {
        user_burn(coin);
    }

    //////// 0L ////////
    /// user can burn own coin they are holding.
    /// must be a Friend function, because the relevant tracking
    /// happens in Burn.move
    public(friend) fun user_burn<CoinType>(
        coin: Coin<CoinType>,
    ) acquires CoinInfo { // cannot abort
        if (value(&coin) == 0) {
          destroy_zero(coin);
          return
        };

        let Coin { value: amount } = coin;

        let maybe_supply = &mut borrow_global_mut<CoinInfo<CoinType>>(coin_address<CoinType>()).supply;
        if (option::is_some(maybe_supply)) {
            let supply = option::borrow_mut(maybe_supply);
            optional_aggregator::sub(supply, (amount as u128));
        }
    }

    /// Burn `coin` from the specified `account` with capability.
    /// The capability `burn_cap` should be passed as a reference to `BurnCapability<CoinType>`.
    /// This function shouldn't fail as it's called as part of transaction fee burning.
    ///
    /// Note: This bypasses CoinStore::frozen -- coins within a frozen CoinStore
    /// can be burned.

    // // 0L: is this deprecated?
    // public(friend) fun burn_from<CoinType>(
    //     account_addr: address,
    //     amount: u64,
    //     burn_cap: &BurnCapability<CoinType>,
    // ) acquires CoinInfo, CoinStore {
    //     // Skip burning if amount is zero. This shouldn't error out as it's called as part of transaction fee burning.
    //     if (amount == 0) {
    //         return
    //     };

    //     let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);
    //     let coin_to_burn = extract(&mut coin_store.coin, amount);
    //     test_burn(coin_to_burn, burn_cap);
    // }

    /// Deposit the coin balance into the recipient's account and emit an event.
    public(friend) fun deposit<CoinType>(account_addr: address, coin: Coin<CoinType>) acquires CoinStore {
        assert!(
            is_account_registered<CoinType>(account_addr),
            error::not_found(ECOIN_STORE_NOT_PUBLISHED),
        );

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);
        // assert!(
        //     !coin_store.frozen,
        //     error::permission_denied(EFROZEN),
        // );

        event::emit_event<DepositEvent>(
            &mut coin_store.deposit_events,
            DepositEvent { amount: coin.value },
        );

        merge(&mut coin_store.coin, coin);
    }

    /// Destroys a zero-value coin. Calls will fail if the `value` in the passed-in `token` is non-zero
    /// so it is impossible to "burn" any non-zero amount of `Coin` without having
    /// a `BurnCapability` for the specific `CoinType`.
    public(friend) fun destroy_zero<CoinType>(zero_coin: Coin<CoinType>) {
        let Coin { value } = zero_coin;
        assert!(value == 0, error::invalid_argument(EDESTRUCTION_OF_NONZERO_TOKEN))
    }

    /// Extracts `amount` from the passed-in `coin`, where the original token is modified in place.
    // NOTE: does not need to be friend only, since it is a method (requires a mutable coin already be out of an account);
    public(friend) fun extract<CoinType>(coin: &mut Coin<CoinType>, amount: u64): Coin<CoinType> {
        assert!(coin.value >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));
        coin.value = coin.value - amount;
        Coin { value: amount }
    }

    /// Extracts the entire amount from the passed-in `coin`, where the original token is modified in place.
    // NOTE: does not need to be friend only, since it is a method (requires a mutable coin already be out of an account);

    public(friend) fun extract_all<CoinType>(coin: &mut Coin<CoinType>): Coin<CoinType> {
        let total_value = coin.value;
        coin.value = 0;
        Coin { value: total_value }
    }

    // NOTE(deprecated): SILLY RABBIT, TRICKS ARE FOR KIDS

    /// Creates a new Coin with given `CoinType` and returns minting/freezing/burning capabilities.
    /// The given signer also becomes the account hosting the information  about the coin
    /// (name, supply, etc.). Supply is initialized as non-parallelizable integer.
    public(friend) fun initialize<CoinType>(
        account: &signer,
        name: string::String,
        symbol: string::String,
        decimals: u8,
        monitor_supply: bool,
    ): (BurnCapability<CoinType>, FreezeCapability<CoinType>, MintCapability<CoinType>) {
        initialize_internal(account, name, symbol, decimals, monitor_supply, false)
    }

    /// Same as `initialize` but supply can be initialized to parallelizable aggregator.
    public(friend) fun initialize_with_parallelizable_supply<CoinType>(
        account: &signer,
        name: string::String,
        symbol: string::String,
        decimals: u8,
        monitor_supply: bool,
    ): (BurnCapability<CoinType>, FreezeCapability<CoinType>, MintCapability<CoinType>) {
        system_addresses::assert_diem_framework(account);
        initialize_internal(account, name, symbol, decimals, monitor_supply, true)
    }

    fun initialize_internal<CoinType>(
        account: &signer,
        name: string::String,
        symbol: string::String,
        decimals: u8,
        monitor_supply: bool,
        parallelizable: bool,
    ): (BurnCapability<CoinType>, FreezeCapability<CoinType>, MintCapability<CoinType>) {
        let account_addr = signer::address_of(account);

        assert!(
            coin_address<CoinType>() == account_addr,
            error::invalid_argument(ECOIN_INFO_ADDRESS_MISMATCH),
        );

        assert!(
            !exists<CoinInfo<CoinType>>(account_addr),
            error::already_exists(ECOIN_INFO_ALREADY_PUBLISHED),
        );

        assert!(string::length(&name) <= MAX_COIN_NAME_LENGTH, error::invalid_argument(ECOIN_NAME_TOO_LONG));
        assert!(string::length(&symbol) <= MAX_COIN_SYMBOL_LENGTH, error::invalid_argument(ECOIN_SYMBOL_TOO_LONG));

        let coin_info = CoinInfo<CoinType> {
            name,
            symbol,
            decimals,
            supply: if (monitor_supply) { option::some(optional_aggregator::new(MAX_U128, parallelizable)) } else { option::none() },
        };
        move_to(account, coin_info);

        (BurnCapability<CoinType> {}, FreezeCapability<CoinType> {}, MintCapability<CoinType> {})
    }

    /// "Merges" the two given coins.  The coin passed in as `dst_coin` will have a value equal
    /// to the sum of the two tokens (`dst_coin` and `source_coin`).
    // NOTE: ok to not be a friend function, since these coins had to be withdrawn through the ol_account pathway
    public(friend) fun merge<CoinType>(dst_coin: &mut Coin<CoinType>, source_coin: Coin<CoinType>) {
        spec {
            assume dst_coin.value + source_coin.value <= MAX_U64;
        };
        let Coin { value } = source_coin;
        dst_coin.value = dst_coin.value + value;
    }

    /// Mint new `Coin` with capability.
    /// The capability `_cap` should be passed as reference to `MintCapability<CoinType>`.
    /// Returns minted `Coin`.
    public(friend) fun mint<CoinType>(
        amount: u64,
        _cap: &MintCapability<CoinType>,
    ): Coin<CoinType> acquires CoinInfo {
        if (amount == 0) {
            return zero<CoinType>()
        };

        let maybe_supply = &mut borrow_global_mut<CoinInfo<CoinType>>(coin_address<CoinType>()).supply;
        if (option::is_some(maybe_supply)) {
            let supply = option::borrow_mut(maybe_supply);
            optional_aggregator::add(supply, (amount as u128));
        };

        Coin<CoinType> { value: amount }
    }

    #[test_only]
    public fun test_mint<CoinType>(
      amount: u64,
      cap: &MintCapability<CoinType>,
    ): Coin<CoinType> acquires CoinInfo {
      mint<CoinType>(amount, cap)
    }
    //////// 0L ////////
    // the VM needs to mint only once in 0L for genesis.
    // in gas_coin there are some helpers for test suite minting.
    // otherwise there is no ongoing minting except at genesis
    public(friend) fun vm_mint<CoinType>(
        root: &signer,
        amount: u64,
    ): Coin<CoinType> acquires CoinInfo {
        system_addresses::assert_ol(root);
        // chain_status::assert_genesis(); // TODO: make this assert genesis.

        if (amount == 0) {
            return zero<CoinType>()
        };

        let maybe_supply = &mut borrow_global_mut<CoinInfo<CoinType>>(coin_address<CoinType>()).supply;
        if (option::is_some(maybe_supply)) {
            let supply = option::borrow_mut(maybe_supply);
            optional_aggregator::add(supply, (amount as u128));
        };

        Coin<CoinType> { value: amount }
    }

    // regsister a user to receive a coin type.
    // NOTE: does not need to be a friend, and may be needed for third party applications.
    public(friend) fun register<CoinType>(account: &signer) {
        let account_addr = signer::address_of(account);
        // Short-circuit and do nothing if account is already registered for CoinType.
        if (is_account_registered<CoinType>(account_addr)) {
            return
        };

        account::register_coin<CoinType>(account_addr);
        let coin_store = CoinStore<CoinType> {
            coin: Coin { value: 0 },
            // frozen: false,
            deposit_events: account::new_event_handle<DepositEvent>(account),
            withdraw_events: account::new_event_handle<WithdrawEvent>(account),
        };
        move_to(account, coin_store);
    }

    // NOTE 0L: Locking down transfers so that only system contracts can use this
    // to enforce transfer limits on higher order contracts.
    /// Transfers `amount` of coins `CoinType` from `from` to `to`.
    public(friend) fun transfer<CoinType>(
        from: &signer,
        to: address,
        amount: u64,
    ) acquires CoinStore {
        let coin = withdraw<CoinType>(from, amount);
        deposit(to, coin);
    }

    /// Returns the `value` passed in `coin`.
    public fun value<CoinType>(coin: &Coin<CoinType>): u64 {
        coin.value
    }

    /// Returns an indexed value based on the current supply, compared to the
    /// final supply
    public(friend) fun index_value<CoinType>(coin: &Coin<CoinType>, index_supply: u128):
    u128 acquires CoinInfo {
        let units = (value(coin) as u128);
        let supply_now_opt = supply<CoinType>();
        let supply_now = option::borrow(&supply_now_opt);
        math128::mul_div(units, *supply_now, index_supply)
    }

    /// Withdraw specifed `amount` of coin `CoinType` from the signing account.
    public(friend) fun withdraw<CoinType>(
        account: &signer,
        amount: u64,
    ): Coin<CoinType> acquires CoinStore {
        let account_addr = signer::address_of(account);
        assert!(
            is_account_registered<CoinType>(account_addr),
            error::not_found(ECOIN_STORE_NOT_PUBLISHED),
        );

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);
        // assert!(
        //     !coin_store.frozen,
        //     error::permission_denied(EFROZEN),
        // );

        event::emit_event<WithdrawEvent>(
            &mut coin_store.withdraw_events,
            WithdrawEvent { amount },
        );

        extract(&mut coin_store.coin, amount)
    }

    /// DANGER: only to be used by vm in friend functions
    public(friend) fun vm_withdraw<CoinType>(
        vm: &signer,
        account_addr: address,
        amount: u64,
    ): Option<Coin<CoinType>> acquires CoinStore {
        system_addresses::assert_ol(vm);
        // should never halt
        if (!is_account_registered<CoinType>(account_addr)) return option::none();
        if (amount > balance<CoinType>(account_addr)) return option::none();

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);

        event::emit_event<WithdrawEvent>(
            &mut coin_store.withdraw_events,
            WithdrawEvent { amount },
        );

        option::some(extract(&mut coin_store.coin, amount))
    }

    /// DANGER: only to be used by vm in friend functions
    public(friend) fun withdraw_with_capability<CoinType>(
        cap: &WithdrawCapability,
        amount: u64,
    ): Coin<CoinType> acquires CoinStore {
        let account_addr = account::get_withdraw_cap_address(cap);

        // can halt in transaction
        assert!(
            is_account_registered<CoinType>(account_addr),
            error::not_found(ECOIN_STORE_NOT_PUBLISHED),
        );

        assert!(
            balance<CoinType>(account_addr) > amount,
            error::invalid_argument(EINSUFFICIENT_BALANCE),
        );

        let coin_store = borrow_global_mut<CoinStore<CoinType>>(account_addr);

        event::emit_event<WithdrawEvent>(
            &mut coin_store.withdraw_events,
            WithdrawEvent { amount },
        );

        extract(&mut coin_store.coin, amount)
    }

    /// Create a new `Coin<CoinType>` with a value of `0`.
    public(friend) fun zero<CoinType>(): Coin<CoinType> {
        Coin<CoinType> {
            value: 0
        }
    }

    /// SILLY RABBIT, TRICKS ARE FOR KIDS
    /// Destroy a freeze capability. Freeze capability is dangerous and therefore should be destroyed if not used.
    public(friend) fun destroy_freeze_cap<CoinType>(freeze_cap: FreezeCapability<CoinType>) {
        let FreezeCapability<CoinType> {} = freeze_cap;
    }

    /// Destroy a mint capability.
    public(friend) fun destroy_mint_cap<CoinType>(mint_cap: MintCapability<CoinType>) {
        let MintCapability<CoinType> {} = mint_cap;
    }

    /// Destroy a burn capability.
    public(friend) fun destroy_burn_cap<CoinType>(burn_cap: BurnCapability<CoinType>) {
        let BurnCapability<CoinType> {} = burn_cap;
    }

    #[test_only]
    struct FakeMoney {}

    #[test_only]
    struct FakeMoneyCapabilities has key {
        burn_cap: BurnCapability<FakeMoney>,
        freeze_cap: FreezeCapability<FakeMoney>,
        mint_cap: MintCapability<FakeMoney>,
    }

    #[test_only]
    fun initialize_fake_money(
        account: &signer,
        decimals: u8,
        monitor_supply: bool,
    ): (BurnCapability<FakeMoney>, FreezeCapability<FakeMoney>, MintCapability<FakeMoney>) {
        aggregator_factory::initialize_aggregator_factory_for_test(account);
        initialize<FakeMoney>(
            account,
            string::utf8(b"Fake money"),
            string::utf8(b"FMD"),
            decimals,
            monitor_supply
        )
    }

    #[test_only]
    fun initialize_and_register_fake_money(
        account: &signer,
        decimals: u8,
        monitor_supply: bool,
    ): (BurnCapability<FakeMoney>, FreezeCapability<FakeMoney>, MintCapability<FakeMoney>) {
        let (burn_cap, freeze_cap, mint_cap) = initialize_fake_money(
            account,
            decimals,
            monitor_supply
        );
        register<FakeMoney>(account);
        (burn_cap, freeze_cap, mint_cap)
    }

    #[test_only]
    fun create_fake_money(
        source: &signer,
        destination: &signer,
        amount: u64
    ) acquires CoinInfo, CoinStore {
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(source, 18, true);

        register<FakeMoney>(destination);
        let coins_minted = mint<FakeMoney>(amount, &mint_cap);
        deposit(signer::address_of(source), coins_minted);
        move_to(source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x1, destination = @0x2)]
    fun end_to_end(
        source: signer,
        destination: signer,
    ) acquires CoinInfo, CoinStore {
        let source_addr = signer::address_of(&source);
        account::create_account_for_test(source_addr);
        let destination_addr = signer::address_of(&destination);
        account::create_account_for_test(destination_addr);

        let name = string::utf8(b"Fake money");
        let symbol = string::utf8(b"FMD");

        aggregator_factory::initialize_aggregator_factory_for_test(&source);
        let (burn_cap, freeze_cap, mint_cap) = initialize<FakeMoney>(
            &source,
            name,
            symbol,
            18,
            true
        );
        register<FakeMoney>(&source);
        register<FakeMoney>(&destination);
        assert!(*option::borrow(&supply<FakeMoney>()) == 0, 0);

        assert!(name<FakeMoney>() == name, 1);
        assert!(symbol<FakeMoney>() == symbol, 2);
        assert!(decimals<FakeMoney>() == 18, 3);

        let coins_minted = mint<FakeMoney>(100, &mint_cap);
        deposit(source_addr, coins_minted);
        transfer<FakeMoney>(&source, destination_addr, 50);

        assert!(balance<FakeMoney>(source_addr) == 50, 4);
        assert!(balance<FakeMoney>(destination_addr) == 50, 5);
        assert!(*option::borrow(&supply<FakeMoney>()) == 100, 6);

        let coin = withdraw<FakeMoney>(&source, 10);
        assert!(value(&coin) == 10, 7);
        test_burn(coin, &burn_cap);
        assert!(*option::borrow(&supply<FakeMoney>()) == 90, 8);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x1, destination = @0x2)]
    fun end_to_end_no_supply(
        source: signer,
        destination: signer,
    ) acquires CoinInfo, CoinStore {
        let source_addr = signer::address_of(&source);
        account::create_account_for_test(source_addr);
        let destination_addr = signer::address_of(&destination);
        account::create_account_for_test(destination_addr);

        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&source, 1, false);

        register<FakeMoney>(&destination);
        assert!(option::is_none(&supply<FakeMoney>()), 0);

        let coins_minted = mint<FakeMoney>(100, &mint_cap);
        deposit<FakeMoney>(source_addr, coins_minted);
        transfer<FakeMoney>(&source, destination_addr, 50);

        assert!(balance<FakeMoney>(source_addr) == 50, 1);
        assert!(balance<FakeMoney>(destination_addr) == 50, 2);
        assert!(option::is_none(&supply<FakeMoney>()), 3);

        let coin = withdraw<FakeMoney>(&source, 10);
        test_burn(coin, &burn_cap);
        assert!(option::is_none(&supply<FakeMoney>()), 4);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x2, framework = @diem_framework)]
    #[expected_failure(abort_code = 0x10001, location = Self)]
    public fun fail_initialize(source: signer, framework: signer) {
        aggregator_factory::initialize_aggregator_factory_for_test(&framework);
        let (burn_cap, freeze_cap, mint_cap) = initialize<FakeMoney>(
            &source,
            string::utf8(b"Fake money"),
            string::utf8(b"FMD"),
            1,
            true,
        );

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x1, destination = @0x2)]
    #[expected_failure(abort_code = 0x60005, location = Self)]
    fun fail_transfer(
        source: signer,
        destination: signer,
    ) acquires CoinInfo, CoinStore {
        let source_addr = signer::address_of(&source);
        account::create_account_for_test(source_addr);
        let destination_addr = signer::address_of(&destination);
        account::create_account_for_test(destination_addr);

        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&source, 1, true);
        assert!(*option::borrow(&supply<FakeMoney>()) == 0, 0);

        let coins_minted = mint<FakeMoney>(100, &mint_cap);
        deposit(source_addr, coins_minted);
        transfer<FakeMoney>(&source, destination_addr, 50);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    // #[test(source = @0x1, destination = @0x2)]
    // fun test_burn_from_with_capability(
    //     source: signer,
    // ) acquires CoinInfo, CoinStore {
    //     let source_addr = signer::address_of(&source);
    //     account::create_account_for_test(source_addr);
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&source, 1, true);

    //     let coins_minted = mint<FakeMoney>(100, &mint_cap);
    //     deposit(source_addr, coins_minted);
    //     assert!(balance<FakeMoney>(source_addr) == 100, 0);
    //     assert!(*option::borrow(&supply<FakeMoney>()) == 100, 1);

    //     burn_from<FakeMoney>(source_addr, 10, &burn_cap);
    //     assert!(balance<FakeMoney>(source_addr) == 90, 2);
    //     assert!(*option::borrow(&supply<FakeMoney>()) == 90, 3);

    //     move_to(&source, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    #[test(source = @0x1)]
    #[expected_failure(abort_code = 0x10007, location = Self)]
    public fun test_destroy_non_zero(
        source: signer,
    ) acquires CoinInfo {
        account::create_account_for_test(signer::address_of(&source));
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&source, 1, true);
        let coins_minted = mint<FakeMoney>(100, &mint_cap);
        destroy_zero(coins_minted);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x1)]
    fun test_extract(
        source: signer,
    ) acquires CoinInfo, CoinStore {
        let source_addr = signer::address_of(&source);
        account::create_account_for_test(source_addr);
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&source, 1, true);

        let coins_minted = mint<FakeMoney>(100, &mint_cap);

        let extracted = extract(&mut coins_minted, 25);
        assert!(value(&coins_minted) == 75, 0);
        assert!(value(&extracted) == 25, 1);

        deposit(source_addr, coins_minted);
        deposit(source_addr, extracted);

        assert!(balance<FakeMoney>(source_addr) == 100, 2);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(source = @0x1)]
    public fun test_is_coin_initialized(source: signer) {
        assert!(!is_coin_initialized<FakeMoney>(), 0);

        let (burn_cap, freeze_cap, mint_cap) = initialize_fake_money(&source, 1, true);
        assert!(is_coin_initialized<FakeMoney>(), 1);

        move_to(&source, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test]
    fun test_zero() {
        let zero = zero<FakeMoney>();
        assert!(value(&zero) == 0, 1);
        destroy_zero(zero);
    }

    // #[test(account = @0x1)]
    // fun burn_frozen(account: signer) acquires CoinInfo, CoinStore {
    //     let account_addr = signer::address_of(&account);
    //     account::create_account_for_test(account_addr);
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&account, 18, true);

    //     let coins_minted = mint<FakeMoney>(100, &mint_cap);
    //     deposit(account_addr, coins_minted);

    //     freeze_coin_store(account_addr, &freeze_cap);
    //     burn_from(account_addr, 100, &burn_cap);

    //     move_to(&account, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    // #[test(account = @0x1)]
    // #[expected_failure(abort_code = 0x5000A, location = Self)]
    // fun withdraw_frozen(account: signer) acquires CoinInfo, CoinStore {
    //     let account_addr = signer::address_of(&account);
    //     account::create_account_for_test(account_addr);
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&account, 18, true);

    //     freeze_coin_store(account_addr, &freeze_cap);
    //     let coin = withdraw<FakeMoney>(&account, 10);
    //     test_burn(coin, &burn_cap);

    //     move_to(&account, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    // #[test(account = @0x1)]
    // #[expected_failure(abort_code = 0x5000A, location = Self)]
    // fun deposit_frozen(account: signer) acquires CoinInfo, CoinStore {
    //     let account_addr = signer::address_of(&account);
    //     account::create_account_for_test(account_addr);
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&account, 18, true);

    //     let coins_minted = mint<FakeMoney>(100, &mint_cap);
    //     freeze_coin_store(account_addr, &freeze_cap);
    //     deposit(account_addr, coins_minted);

    //     move_to(&account, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    // #[test(account = @0x1)]
    // fun deposit_widthdraw_unfrozen(account: signer) acquires CoinInfo, CoinStore {
    //     let account_addr = signer::address_of(&account);
    //     account::create_account_for_test(account_addr);
    //     let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&account, 18, true);

    //     let coins_minted = mint<FakeMoney>(100, &mint_cap);
    //     freeze_coin_store(account_addr, &freeze_cap);
    //     unfreeze_coin_store(account_addr, &freeze_cap);
    //     deposit(account_addr, coins_minted);

    //     freeze_coin_store(account_addr, &freeze_cap);
    //     unfreeze_coin_store(account_addr, &freeze_cap);
    //     let coin = withdraw<FakeMoney>(&account, 10);
    //     test_burn(coin, &burn_cap);

    //     move_to(&account, FakeMoneyCapabilities {
    //         burn_cap,
    //         freeze_cap,
    //         mint_cap,
    //     });
    // }

    #[test_only]
    fun initialize_with_aggregator(account: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = initialize_with_parallelizable_supply<FakeMoney>(
            account,
            string::utf8(b"Fake money"),
            string::utf8(b"FMD"),
            1,
            true
        );
        move_to(account, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test_only]
    fun initialize_with_integer(account: &signer) {
        let (burn_cap, freeze_cap, mint_cap) = initialize<FakeMoney>(
            account,
            string::utf8(b"Fake money"),
            string::utf8(b"FMD"),
            1,
            true
        );
        move_to(account, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(framework = @diem_framework, other = @0x123)]
    #[expected_failure(abort_code = 0x50003, location = diem_framework::system_addresses)]
    fun test_supply_initialize_fails(framework: signer, other: signer) {
        aggregator_factory::initialize_aggregator_factory_for_test(&framework);
        initialize_with_aggregator(&other);
    }

    #[test(framework = @diem_framework)]
    fun test_supply_initialize(framework: signer) acquires CoinInfo {
        aggregator_factory::initialize_aggregator_factory_for_test(&framework);
        initialize_with_aggregator(&framework);

        let maybe_supply = &mut borrow_global_mut<CoinInfo<FakeMoney>>(coin_address<FakeMoney>()).supply;
        let supply = option::borrow_mut(maybe_supply);

        // Supply should be parallelizable.
        assert!(optional_aggregator::is_parallelizable(supply), 0);

        optional_aggregator::add(supply, 100);
        optional_aggregator::sub(supply, 50);
        optional_aggregator::add(supply, 950);
        assert!(optional_aggregator::read(supply) == 1000, 0);
    }

    #[test(framework = @diem_framework)]
    #[expected_failure(abort_code = 0x20001, location = diem_framework::aggregator)]
    fun test_supply_overflow(framework: signer) acquires CoinInfo {
        aggregator_factory::initialize_aggregator_factory_for_test(&framework);
        initialize_with_aggregator(&framework);

        let maybe_supply = &mut borrow_global_mut<CoinInfo<FakeMoney>>(coin_address<FakeMoney>()).supply;
        let supply = option::borrow_mut(maybe_supply);

        optional_aggregator::add(supply, MAX_U128);
        optional_aggregator::add(supply, 1);
        optional_aggregator::sub(supply, 1);
    }

    // #[test(framework = @diem_framework)]
    // #[expected_failure(abort_code = 0x5000B, location = diem_framework::coin)]
    // fun test_supply_upgrade_fails(framework: signer) acquires CoinInfo, SupplyConfig {
    //     initialize_supply_config(&framework);
    //     aggregator_factory::initialize_aggregator_factory_for_test(&framework);
    //     initialize_with_integer(&framework);

    //     let maybe_supply = &mut borrow_global_mut<CoinInfo<FakeMoney>>(coin_address<FakeMoney>()).supply;
    //     let supply = option::borrow_mut(maybe_supply);

    //     // Supply should be non-parallelizable.
    //     assert!(!optional_aggregator::is_parallelizable(supply), 0);

    //     optional_aggregator::add(supply, 100);
    //     optional_aggregator::sub(supply, 50);
    //     optional_aggregator::add(supply, 950);
    //     assert!(optional_aggregator::read(supply) == 1000, 0);

    //     upgrade_supply<FakeMoney>(&framework);
    // }

    // #[test(framework = @diem_framework)]
    // fun test_supply_upgrade(framework: signer) acquires CoinInfo, SupplyConfig {
    //     initialize_supply_config(&framework);
    //     aggregator_factory::initialize_aggregator_factory_for_test(&framework);
    //     initialize_with_integer(&framework);

    //     // Ensure we have a non-parellelizable non-zero supply.
    //     let maybe_supply = &mut borrow_global_mut<CoinInfo<FakeMoney>>(coin_address<FakeMoney>()).supply;
    //     let supply = option::borrow_mut(maybe_supply);
    //     assert!(!optional_aggregator::is_parallelizable(supply), 0);
    //     optional_aggregator::add(supply, 100);

    //     // Upgrade.
    //     allow_supply_upgrades(&framework, true);
    //     upgrade_supply<FakeMoney>(&framework);

    //     // Check supply again.
    //     let maybe_supply = &mut borrow_global_mut<CoinInfo<FakeMoney>>(coin_address<FakeMoney>()).supply;
    //     let supply = option::borrow_mut(maybe_supply);
    //     assert!(optional_aggregator::is_parallelizable(supply), 0);
    //     assert!(optional_aggregator::read(supply) == 100, 0);
    // }

    #[test_only]
    fun destroy_aggregatable_coin_for_test<CoinType>(aggregatable_coin: AggregatableCoin<CoinType>) {
        let AggregatableCoin { value } = aggregatable_coin;
        aggregator::destroy(value);
    }

    #[test(framework = @diem_framework)]
    fun test_register_twice_should_not_fail(framework: &signer) {
        let framework_addr = signer::address_of(framework);
        account::create_account_for_test(framework_addr);
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(framework, 1, true);

        // Registering twice should not fail.
        assert!(is_account_registered<FakeMoney>(@0x1), 0);
        register<FakeMoney>(framework);
        assert!(is_account_registered<FakeMoney>(@0x1), 1);

        move_to(framework, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }

    #[test(framework = @diem_framework)]
    fun test_collect_from_and_drain(
        framework: signer,
    ) acquires CoinInfo, CoinStore {
        let framework_addr = signer::address_of(&framework);
        account::create_account_for_test(framework_addr);
        let (burn_cap, freeze_cap, mint_cap) = initialize_and_register_fake_money(&framework, 1, true);

        let coins_minted = mint<FakeMoney>(100, &mint_cap);
        deposit(framework_addr, coins_minted);
        assert!(balance<FakeMoney>(framework_addr) == 100, 0);
        assert!(*option::borrow(&supply<FakeMoney>()) == 100, 0);

        let aggregatable_coin = initialize_aggregatable_coin<FakeMoney>(&framework);
        collect_into_aggregatable_coin<FakeMoney>(framework_addr, 10, &mut aggregatable_coin);

        // Check that aggregatable coin has the right amount.
        let collected_coin = drain_aggregatable_coin(&mut aggregatable_coin);
        assert!(is_aggregatable_coin_zero(&aggregatable_coin), 0);
        assert!(value(&collected_coin) == 10, 0);

        // Supply of coins should be unchanged, but the balance on the account should decrease.
        assert!(balance<FakeMoney>(framework_addr) == 90, 0);
        assert!(*option::borrow(&supply<FakeMoney>()) == 100, 0);

        test_burn(collected_coin, &burn_cap);
        destroy_aggregatable_coin_for_test(aggregatable_coin);
        move_to(&framework, FakeMoneyCapabilities {
            burn_cap,
            freeze_cap,
            mint_cap,
        });
    }
}

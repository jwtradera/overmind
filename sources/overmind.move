
module overmind::bank {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

//:!:>resource
    struct Deposit<phantom CoinType> has store {
        coins: Coin<CoinType>,
        is_claimed: bool
    }

    struct Bank<phantom CoinType> has key {
        authority_addr: address,
        depositors_limit: u64,
        depositors_count: u64,
        withdrawers_count: u64,
        deposit_amount: u64,
        expiry_time: u64,
        withdraw_weights: vector<u64>,
        depositors: Table<address, Deposit<CoinType>>,
    }
//<:!:resource

    /// Error codes
    const EACCOUNT_ALREADY_INITIALIZED: u64 = 1;
    const EINVALID_DEPOSIOTRS_LIMIT: u64 = 2;
    const EINVALID_WITHDRAW_WEIGHT: u64 = 3;
    const EINVALID_WITHDRAW_WEIGHTS_SUM: u64 = 4;
    const ECANNOT_DEPOSIT_AFTER_EXPIRATION_TIME: u64 = 5;
    const ECANNOT_WITHDRAW_AFTER_EXPIRATION_TIME: u64 = 6;
    const EDEPOSITOR_ALREADY_EXISTS: u64 = 7;
    const ECANNOT_DEPOSIT_AFTER_POOL_IS_FULL: u64 = 8;
    const ECANNOT_WITHDRAW_BEFORE_DEPOSIT : u64 = 9;
    const ECANNOT_WITHDRAW_AGAIN : u64 = 10;

    /// Basis points
    const BASIS_POINTS: u64 = 1000;

    /// Instructions
    public entry fun initialize_deposits<CoinType>(account: &signer, depositors_limit: u64, deposit_amount: u64, expiry_time: u64, withdraw_weights: vector<u64>) {
        let authority_addr = signer::address_of(account);
        assert!(!exists<Bank<CoinType>>(authority_addr), error::already_exists(EACCOUNT_ALREADY_INITIALIZED));

        // Check withdraw weights
        let len = vector::length(&withdraw_weights);
        assert!(len == depositors_limit, error::invalid_argument(EINVALID_DEPOSIOTRS_LIMIT));

        let i = 0;
        let previous_weight = 0;
        let sum = 0;
        while (i < len) {
            let weight = *vector::borrow(&withdraw_weights, i);
            assert!(weight > 0, error::invalid_argument(EINVALID_WITHDRAW_WEIGHT));
            assert!(weight >= previous_weight, error::invalid_argument(EINVALID_WITHDRAW_WEIGHT));

            previous_weight = weight;
            sum = sum + weight;
            i = i + 1;
        };

        assert!(sum == BASIS_POINTS, error::invalid_argument(EINVALID_WITHDRAW_WEIGHTS_SUM));
        
        move_to(account, Bank<CoinType> {
            authority_addr,
            depositors_limit,
            depositors_count: 0,
            withdrawers_count: 0,
            deposit_amount,
            expiry_time,
            withdraw_weights,
            depositors: table::new<address, Deposit<CoinType>>()
        })
    }

    public entry fun deposit<CoinType>(depositor: &signer, bank_addr: address) acquires Bank {
        let depositor_addr = signer::address_of(depositor);

        let bank = borrow_global_mut<Bank<CoinType>>(bank_addr);
        let depositors_count = bank.depositors_count;

        // Check expiration
        assert!(timestamp::now_seconds() <= bank.expiry_time, error::permission_denied(ECANNOT_DEPOSIT_AFTER_EXPIRATION_TIME));

        // Check depositors limit
        assert!(depositors_count < bank.depositors_limit, error::permission_denied(ECANNOT_DEPOSIT_AFTER_POOL_IS_FULL));

        // Check already deposited
        assert!(!table::contains(&bank.depositors, depositor_addr), error::already_exists(EDEPOSITOR_ALREADY_EXISTS));

        // Deposit coins
        let coins = coin::withdraw<CoinType>(depositor, bank.withdrawers_count);
        table::add(&mut bank.depositors, depositor_addr, Deposit<CoinType> { coins, is_claimed: false });

        // Update deposit status
        bank.depositors_count = bank.depositors_count + 1;
    }
    
    public entry fun withdraw<CoinType>(withdrawer: &signer, bank_addr: address) acquires Bank {
        let withdrawer_addr = signer::address_of(withdrawer);

        let bank = borrow_global_mut<Bank<CoinType>>(bank_addr);

        // Check expiration
        assert!(timestamp::now_seconds() <= bank.expiry_time, error::permission_denied(ECANNOT_WITHDRAW_AFTER_EXPIRATION_TIME));

        // Check if deposited
        assert!(table::contains(&mut bank.depositors, withdrawer_addr), error::permission_denied(ECANNOT_WITHDRAW_BEFORE_DEPOSIT));
        let deposit = &mut table::borrow_mut(&mut bank.deposits, withdrawer_addr);

        // Check if already withdrawn
        assert!(!deposit.is_claimed, error::permission_denied(ECANNOT_WITHDRAW_AGAIN));

        // Calculate withdraw amount
        let weight = *vector::borrow(&bank.withdraw_weights, bank.withdrawers_count);
        deposit.coins.value = bank.deposit_amount * bank.depositors_count * weight / BASIS_POINTS;

        // Withdraw coins
        coin::deposit<CoinType>(withdrawer_addr, deposit.coins);

        // Update status
        deposit.is_claimed = true;

        bank.withdrawers_count = bank.withdrawers_count + 1;
    }

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::coin::MintCapability;
    #[test_only]
    use aptos_framework::aptos_coin::AptosCoin;
    #[test_only]
    const DEPOSIT_AMOUNT: u64 = 100;

    #[test_only]
    fun setup(aptos_framework: &signer, depositors: &signer) : MintCapability<AptosCoin> {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<AptosCoin>(
            aptos_framework,
            string::utf8(b"TC"),
            string::utf8(b"TC"),
            8,
            false,
        );
        aptos_framework::account::create_account_for_test(signer::address_of(depositors));
        coin::register<AptosCoin>(depositors);
        let coins = coin::mint<AptosCoin>(1000, &mint_cap);
        coin::deposit(signer::address_of(depositors), coins);
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_burn_cap(burn_cap);
        mint_cap
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10002)]
    public entry fun test_initialize_failed_with_invalid_depositors_limit(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        // Fail with invalid depositors limit
        initialize_deposits<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100]);
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10003)]
    public entry fun test_initialize_failed_with_invalid_depositors_weight(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize_deposits<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[900, 100]);
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_initialize_failed_with_invalid_depositors_weights_sum(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize_deposits<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 800]);
    }

    #[test(account = @0x1)]
    public entry fun test_initialize_successed(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize_deposits<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 900]);
    }

    #[test(aptos_framework = @aptos_framework, bank = @0x1, depositor = @0x234)]
    public entry fun test_deposit_successed(aptos_framework: &signer, depositor: &signer, bank: &signer) acquires Bank {

        let bank_addr = signer::address_of(bank);

        let depositor_addr = signer::address_of(depositor);
        aptos_framework::account::create_account_for_test(depositor_addr);

        initialize_deposits<AptosCoin>(bank, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 900]);
        
        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework, bank);
        coin::register<AptosCoin>(depositor);
        coin::deposit<AptosCoin>(depositor_addr, coin::mint<AptosCoin>(DEPOSIT_AMOUNT, &mint_cap));

        deposit<AptosCoin>(depositor, bank_addr);

        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @aptos_framework, bank = @0x1, withdrawer = @0x234)]
    public entry fun test_withdraw_successed(aptos_framework: &signer, withdrawer: &signer, bank: &signer) acquires Bank {

        let bank_addr = signer::address_of(bank);

        let withdrawer_addr = signer::address_of(withdrawer);
        aptos_framework::account::create_account_for_test(withdrawer_addr);

        initialize_deposits<AptosCoin>(bank, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 900]);
        
        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework, bank);
        coin::register<AptosCoin>(withdrawer);
        coin::deposit<AptosCoin>(withdrawer_addr, coin::mint<AptosCoin>(DEPOSIT_AMOUNT, &mint_cap));

        deposit<AptosCoin>(withdrawer, bank_addr);

        withdraw<AptosCoin>(withdrawer, bank_addr);

        coin::destroy_mint_cap(mint_cap);
    }
}

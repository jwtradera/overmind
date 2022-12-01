
module overmind::bank {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;

//:!:>resource
    struct Deposit has store {
        is_claimed: bool
    }

    struct Bank<phantom CoinType> has key, store {
        authority_addr: address,
        depositors_limit: u64,
        depositors_count: u64,
        withdrawers_count: u64,
        deposit_amount: u64,
        expiry_time: u64,
        withdraw_weights: vector<u64>,
        escrow_coins: Coin<CoinType>,
        depositors: Table<address, Deposit>,
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
    const EDEPOSIT_BALANCE_MISMATCHED : u64 = 11;
    const EWITHDRAW_AMOUNT_MISMATCHED : u64 = 12;

    /// Basis points
    const BASIS_POINTS: u64 = 1000;

    /// Instructions
    public entry fun initialize<CoinType>(account: &signer, depositors_limit: u64, deposit_amount: u64, expiry_time: u64, withdraw_weights: vector<u64>) {
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

        // initialized coin store
        if (!coin::is_account_registered<CoinType>(authority_addr)) {
            coin::register<CoinType>(account);            
        };

        let escrow_coins = coin::withdraw<CoinType>(account, 0);
        
        move_to(account, Bank<CoinType> {
            authority_addr,
            depositors_limit,
            depositors_count: 0,
            withdrawers_count: 0,
            deposit_amount,
            expiry_time,
            withdraw_weights,
            escrow_coins,
            depositors: table::new<address, Deposit>(),
        });
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
        let deposit_coins = coin::withdraw<CoinType>(depositor, bank.deposit_amount);
        let escrow_coins = &mut bank.escrow_coins;
        coin::merge<CoinType>(escrow_coins, deposit_coins);

        table::add(&mut bank.depositors, depositor_addr, Deposit { is_claimed: false });

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

        let deposit = table::borrow_mut(&mut bank.depositors, withdrawer_addr);

        // Check if already withdrawn
        assert!(!deposit.is_claimed, error::permission_denied(ECANNOT_WITHDRAW_AGAIN));

        // Calculate withdraw amount
        let weight = *vector::borrow(&bank.withdraw_weights, bank.withdrawers_count);
        let value = bank.deposit_amount * bank.depositors_count * weight / BASIS_POINTS;

        // Withdraw coins
        let withdrawn_coins = coin::extract(&mut bank.escrow_coins, value);
        coin::deposit(withdrawer_addr, withdrawn_coins);

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
    fun setup(aptos_framework: &signer) : MintCapability<AptosCoin> {
        timestamp::set_time_has_started_for_testing(aptos_framework);

        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<AptosCoin>(
            aptos_framework,
            string::utf8(b"TC"),
            string::utf8(b"TC"),
            8,
            false,
        );
        coin::destroy_freeze_cap(freeze_cap);
        coin::destroy_burn_cap(burn_cap);
        mint_cap
    }

    #[test_only]
    fun create_and_mint_account(account: &signer, mint_cap: &MintCapability<AptosCoin>) {
        // Prepare accounts
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);
        
        coin::register<AptosCoin>(account);
        coin::deposit<AptosCoin>(addr, coin::mint<AptosCoin>(DEPOSIT_AMOUNT, mint_cap));
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10002)]
    public entry fun test_initialize_failed_with_invalid_depositors_limit(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        // Fail with invalid depositors limit
        initialize<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100]);
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10003)]
    public entry fun test_initialize_failed_with_invalid_depositors_weight(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[900, 100]);
    }

    #[test(account = @0x1)]
    #[expected_failure(abort_code = 0x10004)]
    public entry fun test_initialize_failed_with_invalid_depositors_weights_sum(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 800]);
    }

    #[test(account = @0x1)]
    public entry fun test_initialize_successed(account: &signer) {
        let addr = signer::address_of(account);
        aptos_framework::account::create_account_for_test(addr);

        initialize<AptosCoin>(account, 2, DEPOSIT_AMOUNT, 0, vector<u64>[100, 900]);
    }
    
    #[test(aptos_framework = @aptos_framework, bank = @0x1, depositor = @0x234)]
    #[expected_failure(abort_code = 0x50008)]
    public entry fun test_deposit_failed_with_repeat(aptos_framework: &signer, bank: &signer, depositor: &signer) acquires Bank {

        // Prepare accounts
        let bank_addr = signer::address_of(bank);
        aptos_framework::account::create_account_for_test(bank_addr);

        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework);
        create_and_mint_account(depositor, &mint_cap);

        // Test multiple deposits
        initialize<AptosCoin>(bank, 1, DEPOSIT_AMOUNT, 0, vector<u64>[1000]);

        // Deposit 2 times as same address
        deposit<AptosCoin>(depositor, bank_addr);
        deposit<AptosCoin>(depositor, bank_addr);
        
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(aptos_framework = @aptos_framework, bank = @0x1, depositor1 = @0x231, depositor2 = @0x232, depositor3 = @0x233)]
    public entry fun test_deposit_successed(aptos_framework: &signer, bank: &signer, depositor1: &signer, depositor2: &signer, depositor3: &signer) acquires Bank {

        // Prepare accounts
        let bank_addr = signer::address_of(bank);
        aptos_framework::account::create_account_for_test(bank_addr);

        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework);
        create_and_mint_account(depositor1, &mint_cap);
        create_and_mint_account(depositor2, &mint_cap);
        create_and_mint_account(depositor3, &mint_cap);

        // Test multiple deposits
        initialize<AptosCoin>(bank, 3, DEPOSIT_AMOUNT, 0, vector<u64>[100, 300, 600]);

        deposit<AptosCoin>(depositor1, bank_addr);
        deposit<AptosCoin>(depositor2, bank_addr);
        deposit<AptosCoin>(depositor3, bank_addr);

        let bank = borrow_global<Bank<AptosCoin>>(bank_addr);

        // Check balance
        assert!(coin::value<AptosCoin>(&bank.escrow_coins) == DEPOSIT_AMOUNT * 3, EDEPOSIT_BALANCE_MISMATCHED);

        coin::destroy_mint_cap(mint_cap);
    }
    
    #[test(aptos_framework = @aptos_framework, bank = @0x1, depositor = @0x234)]
    #[expected_failure(abort_code = 0x5000A)]
    public entry fun test_withdraw_failed_with_repeat(aptos_framework: &signer, bank: &signer, depositor: &signer) acquires Bank {

        // Prepare accounts
        let bank_addr = signer::address_of(bank);
        aptos_framework::account::create_account_for_test(bank_addr);

        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework);
        create_and_mint_account(depositor, &mint_cap);

        // Test multiple deposits
        initialize<AptosCoin>(bank, 1, DEPOSIT_AMOUNT, 0, vector<u64>[1000]);

        deposit<AptosCoin>(depositor, bank_addr);

        // Withdraw 2 times as same address
        withdraw<AptosCoin>(depositor, bank_addr);
        withdraw<AptosCoin>(depositor, bank_addr);
        
        coin::destroy_mint_cap(mint_cap);
    }
    
    #[test(aptos_framework = @aptos_framework, bank = @0x1, depositor1 = @0x231, depositor2 = @0x232, depositor3 = @0x233)]
    public entry fun test_withdraw_successed(aptos_framework: &signer, bank: &signer, depositor1: &signer, depositor2: &signer, depositor3: &signer) acquires Bank {

        // Prepare accounts
        let bank_addr = signer::address_of(bank);
        aptos_framework::account::create_account_for_test(bank_addr);

        // Prepare coins for deposit
        let mint_cap = setup(aptos_framework);
        create_and_mint_account(depositor1, &mint_cap);
        create_and_mint_account(depositor2, &mint_cap);
        create_and_mint_account(depositor3, &mint_cap);

        // Test multiple deposits
        initialize<AptosCoin>(bank, 3, DEPOSIT_AMOUNT, 0, vector<u64>[100, 300, 600]);

        deposit<AptosCoin>(depositor1, bank_addr);
        deposit<AptosCoin>(depositor2, bank_addr);
        deposit<AptosCoin>(depositor3, bank_addr);

        // Withdraw with reverse order
        withdraw<AptosCoin>(depositor3, bank_addr);
        withdraw<AptosCoin>(depositor2, bank_addr);
        withdraw<AptosCoin>(depositor1, bank_addr);

        // Check balance with formular
        // 1st withdrawer: 100 * 3 * 0.1 = 30
        assert!(coin::balance<AptosCoin>(signer::address_of(depositor3)) == 30, EWITHDRAW_AMOUNT_MISMATCHED);
        // 2nd withdrawer: 100 * 3 * 0.3 = 90
        assert!(coin::balance<AptosCoin>(signer::address_of(depositor2)) == 90, EWITHDRAW_AMOUNT_MISMATCHED);
        // 3rd withdrawer: 100 * 3 * 0.6 = 180
        assert!(coin::balance<AptosCoin>(signer::address_of(depositor1)) == 180, EWITHDRAW_AMOUNT_MISMATCHED);

        coin::destroy_mint_cap(mint_cap);
    }
}

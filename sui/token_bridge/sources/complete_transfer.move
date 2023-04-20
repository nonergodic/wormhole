// SPDX-License-Identifier: Apache 2

/// This module implements the method `complete_transfer` which allows someone
/// to redeem a Token Bridge transfer with a specified relayer fee. A VAA with
/// an encoded transfer can be redeemed only once.
///
/// See `transfer` module for serialization and deserialization of Wormhole
/// message payload.
module token_bridge::complete_transfer {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::event::{Self};
    use sui::tx_context::{Self, TxContext};
    use wormhole::external_address::{Self, ExternalAddress};
    use wormhole::vaa::{VAA};

    use token_bridge::native_asset::{Self};
    use token_bridge::normalized_amount::{Self, NormalizedAmount};
    use token_bridge::state::{Self, State};
    use token_bridge::token_registry::{Self, VerifiedAsset};
    use token_bridge::transfer::{Self};
    use token_bridge::vaa::{Self};
    use token_bridge::version_control::{
        CompleteTransfer as CompleteTransferControl
    };
    use token_bridge::wrapped_asset::{Self};

    // Requires `handle_complete_transfer`.
    friend token_bridge::complete_transfer_with_payload;

    const E_TARGET_NOT_SUI: u64 = 0;
    const E_UNREGISTERED_TOKEN: u64 = 1;

    struct TransferRedeemed has drop, copy {
        emitter_chain: u16,
        emitter_address: ExternalAddress,
        sequence: u64
    }

    /// `complete_transfer` takes a verified Wormhole message and validates
    /// that this message was sent by a registered foreign Token Bridge contract
    /// and has a Token Bridge transfer payload.
    ///
    /// After processing the token transfer payload, coins are sent to the
    /// encoded recipient. If the specified `relayer` differs from this
    /// recipient, a relayer fee is split from this coin and sent to `relayer`.
    public fun complete_transfer<CoinType>(
        token_bridge_state: &mut State,
        parsed: VAA,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        state::check_minimum_requirement<CompleteTransferControl>(
            token_bridge_state
        );

        // Verify Token Bridge transfer message. This method guarantees that a
        // verified transfer message cannot be redeemed again.
        let verified = vaa::verify_only_once(token_bridge_state, parsed);

        // Emitting the transfer being redeemed (and disregard return value).
        emit_transfer_redeemed(&verified);

        // Deserialize transfer message and process.
        handle_complete_transfer<CoinType>(
            token_bridge_state,
            wormhole::vaa::take_payload(verified),
            ctx
        )
    }

    /// `verify_and_bridge_out` is only friendly with this module and the
    /// `complete_transfer` module. For inbound transfers, the deserialized
    /// transfer message needs to be validated.
    ///
    /// This method also de-normalizes the amount encoded in the transfer based
    /// on the coin's decimals.
    ///
    /// Depending on whether this coin is a Token Bridge wrapped asset or a
    /// natively existing asset on Sui, the coin is either minted or withdrawn
    /// from Token Bridge's custody.
    public(friend) fun verify_and_bridge_out<CoinType>(
        token_bridge_state: &mut State,
        token_chain: u16,
        token_address: ExternalAddress,
        target_chain: u16,
        amount: NormalizedAmount
    ): (VerifiedAsset<CoinType>, Balance<CoinType>) {
        // Verify that the intended chain ID for this transfer is for Sui.
        assert!(
            target_chain == wormhole::state::chain_id(),
            E_TARGET_NOT_SUI
        );

        let asset_info =
            token_registry::verify_token_info(
                state::borrow_token_registry(token_bridge_state),
                token_chain,
                token_address
            );

        // De-normalize amount in preparation to take `Balance`.
        let raw_amount =
            normalized_amount::to_raw(
                amount,
                token_registry::coin_decimals(&asset_info)
            );

        // If the token is wrapped by Token Bridge, we will mint these tokens.
        // Otherwise, we will withdraw from custody.
        let bridged_out = {
            let registry = state::borrow_mut_token_registry(token_bridge_state);
            if (token_registry::is_wrapped(&asset_info)) {
                wrapped_asset::mint(
                    token_registry::borrow_mut_wrapped(registry),
                    raw_amount
                )
            } else {
                native_asset::withdraw(
                    token_registry::borrow_mut_native(registry),
                    raw_amount
                )
            }
        };

        (asset_info, bridged_out)
    }

    public(friend) fun emit_transfer_redeemed(parsed_vaa: &VAA): u16 {
        let (
            emitter_chain,
            emitter_address,
            sequence
        ) = wormhole::vaa::emitter_info(parsed_vaa);

        // Emit Sui event with `TransferRedeemed`.
        event::emit(
            TransferRedeemed {
                emitter_chain,
                emitter_address,
                sequence
            }
        );

        emitter_chain
    }

    fun handle_complete_transfer<CoinType>(
        token_bridge_state: &mut State,
        transfer_vaa_payload: vector<u8>,
        ctx: &mut TxContext
    ): Coin<CoinType> {
        let (
            amount,
            token_address,
            token_chain,
            recipient,
            recipient_chain,
            relayer_fee
        ) = transfer::unpack(transfer::deserialize(transfer_vaa_payload));

        let (
            verified,
            bridged_out
        ) =
            verify_and_bridge_out(
                token_bridge_state,
                token_chain,
                token_address,
                recipient_chain,
                amount
            );

        let recipient = external_address::to_address(recipient);

        // If the recipient did not redeem his own transfer, Token Bridge will
        // split the withdrawn coins and send a portion to the transaction
        // relayer.
        let payout = if (
            normalized_amount::value(&relayer_fee) == 0 ||
            recipient == tx_context::sender(ctx)
        ) {
            balance::zero()
        } else {
            let payout_amount =
                normalized_amount::to_raw(
                    relayer_fee,
                    token_registry::coin_decimals(&verified)
                );
            balance::split(&mut bridged_out, payout_amount)
        };

        // Finally transfer tokens to the recipient.
        sui::transfer::public_transfer(
            coin::from_balance(bridged_out, ctx),
            recipient
        );

        coin::from_balance(payout, ctx)
    }
}

#[test_only]
module token_bridge::complete_transfer_tests {
    use sui::coin::{Self, Coin};
    use sui::test_scenario::{Self};
    use wormhole::state::{chain_id};
    use wormhole::wormhole_scenario::{parse_and_verify_vaa};

    use token_bridge::coin_wrapped_12::{Self, COIN_WRAPPED_12};
    use token_bridge::coin_wrapped_7::{Self, COIN_WRAPPED_7};
    use token_bridge::coin_native_10::{Self, COIN_NATIVE_10};
    use token_bridge::coin_native_4::{Self, COIN_NATIVE_4};
    use token_bridge::complete_transfer::{Self};
    use token_bridge::dummy_message::{Self};
    use token_bridge::native_asset::{Self};
    use token_bridge::state::{Self};
    use token_bridge::token_bridge_scenario::{
        set_up_wormhole_and_token_bridge,
        register_dummy_emitter,
        return_state,
        take_state,
        three_people
    };
    use token_bridge::token_registry::{Self};
    use token_bridge::transfer::{Self};
    use token_bridge::wrapped_asset::{Self};

    struct OTHER_COIN_WITNESS has drop {}

    #[test]
    /// An end-to-end test for complete transfer native with VAA.
    fun test_complete_transfer_native_10_relayer_fee() {
        let transfer_vaa =
            dummy_message::encoded_transfer_vaa_native_with_fee();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        let custody_amount = 500000;
        coin_native_10::init_register_and_deposit(
            scenario,
            coin_deployer,
            custody_amount
        );

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        // These will be checked later.
        let expected_relayer_fee = 100000;
        let expected_recipient_amount = 200000;
        let expected_amount = expected_relayer_fee + expected_recipient_amount;

        // Scope to allow immutable reference to `TokenRegistry`.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);
            let asset = token_registry::borrow_native<COIN_NATIVE_10>(registry);
            assert!(native_asset::custody(asset) == custody_amount, 0);

            // Verify transfer parameters.
            let parsed =
                transfer::deserialize(
                    wormhole::vaa::take_payload(
                        parse_and_verify_vaa(scenario, transfer_vaa)
                    )
                );

            let verified =
                token_registry::verified_asset<COIN_NATIVE_10>(registry);
            let expected_token_chain = token_registry::token_chain(&verified);
            let expected_token_address =
                token_registry::token_address(&verified);
            assert!(transfer::token_chain(&parsed) == expected_token_chain, 0);
            assert!(transfer::token_address(&parsed) == expected_token_address, 0);

            let decimals =
                state::coin_decimals<COIN_NATIVE_10>(&token_bridge_state);

            assert!(transfer::raw_amount(&parsed, decimals) == expected_amount, 0);

            assert!(
                transfer::raw_relayer_fee(&parsed, decimals) == expected_relayer_fee,
                0
            );
            assert!(
                transfer::recipient_as_address(&parsed) == expected_recipient,
                0
            );
            assert!(transfer::recipient_chain(&parsed) == chain_id(), 0);

            // Clean up.
            transfer::destroy(parsed);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let payout =
            complete_transfer::complete_transfer<COIN_NATIVE_10>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );
        assert!(coin::value(&payout) == expected_relayer_fee, 0);

        // TODO: Check for one event? `TransferRedeemed`.
        let _effects = test_scenario::next_tx(scenario, tx_relayer);

        // Check recipient's `Coin`.
        let received =
            test_scenario::take_from_address<Coin<COIN_NATIVE_10>>(
                scenario,
                expected_recipient
            );
        assert!(coin::value(&received) == expected_recipient_amount, 0);

        // And check remaining amount in custody.
        let registry = state::borrow_token_registry(&token_bridge_state);
        let remaining = custody_amount - expected_amount;
        {
            let asset = token_registry::borrow_native<COIN_NATIVE_10>(registry);
            assert!(native_asset::custody(asset) == remaining, 0);
        };

        // Clean up.
        coin::burn_for_testing(payout);
        coin::burn_for_testing(received);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    /// An end-to-end test for complete transfer native with VAA.
    fun test_complete_transfer_native_4_relayer_fee() {
        let transfer_vaa =
            dummy_message::encoded_transfer_vaa_native_with_fee();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        let custody_amount = 5000;
        coin_native_4::init_register_and_deposit(
            scenario,
            coin_deployer,
            custody_amount
        );

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        // These will be checked later.
        let expected_relayer_fee = 1000;
        let expected_recipient_amount = 2000;
        let expected_amount = expected_relayer_fee + expected_recipient_amount;

        // Scope to allow immutable reference to `TokenRegistry`.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);
            let asset = token_registry::borrow_native<COIN_NATIVE_4>(registry);
            assert!(native_asset::custody(asset) == custody_amount, 0);

            // Verify transfer parameters.
            let parsed =
                transfer::deserialize(
                    wormhole::vaa::take_payload(
                        parse_and_verify_vaa(scenario, transfer_vaa)
                    )
                );

            let verified =
                token_registry::verified_asset<COIN_NATIVE_4>(registry);
            let expected_token_chain = token_registry::token_chain(&verified);
            let expected_token_address =
                token_registry::token_address(&verified);
            assert!(transfer::token_chain(&parsed) == expected_token_chain, 0);
            assert!(transfer::token_address(&parsed) == expected_token_address, 0);

            let decimals =
                state::coin_decimals<COIN_NATIVE_4>(&token_bridge_state);

            assert!(transfer::raw_amount(&parsed, decimals) == expected_amount, 0);

            assert!(
                transfer::raw_relayer_fee(&parsed, decimals) == expected_relayer_fee,
                0
            );
            assert!(
                transfer::recipient_as_address(&parsed) == expected_recipient,
                0
            );
            assert!(transfer::recipient_chain(&parsed) == chain_id(), 0);

            // Clean up.
            transfer::destroy(parsed);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let payout =
            complete_transfer::complete_transfer<COIN_NATIVE_4>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );
        assert!(coin::value(&payout) == expected_relayer_fee, 0);

        // TODO: Check for one event? `TransferRedeemed`.
        let _effects = test_scenario::next_tx(scenario, tx_relayer);

        // Check recipient's `Coin`.
        let received =
            test_scenario::take_from_address<Coin<COIN_NATIVE_4>>(
                scenario,
                expected_recipient
            );
        assert!(coin::value(&received) == expected_recipient_amount, 0);

        // And check remaining amount in custody.
        let registry = state::borrow_token_registry(&token_bridge_state);
        let remaining = custody_amount - expected_amount;
        {
            let asset = token_registry::borrow_native<COIN_NATIVE_4>(registry);
            assert!(native_asset::custody(asset) == remaining, 0);
        };

        // Clean up.
        coin::burn_for_testing(payout);
        coin::burn_for_testing(received);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    /// An end-to-end test for complete transfer wrapped with VAA.
    fun test_complete_transfer_wrapped_7_relayer_fee() {
        let transfer_vaa = dummy_message::encoded_transfer_vaa_wrapped_7_with_fee();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        coin_wrapped_7::init_and_register(scenario, coin_deployer);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        // These will be checked later.
        let expected_relayer_fee = 1000;
        let expected_recipient_amount = 2000;
        let expected_amount = expected_relayer_fee + expected_recipient_amount;

        // Scope to allow immutable reference to `TokenRegistry`.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);
            let asset =
                token_registry::borrow_wrapped<COIN_WRAPPED_7>(registry);
            assert!(wrapped_asset::total_supply(asset) == 0, 0);

            // Verify transfer parameters.
            let parsed =
                transfer::deserialize(
                    wormhole::vaa::take_payload(
                        parse_and_verify_vaa(scenario, transfer_vaa)
                    )
                );

            let verified =
                token_registry::verified_asset<COIN_WRAPPED_7>(registry);
            let expected_token_chain = token_registry::token_chain(&verified);
            let expected_token_address =
                token_registry::token_address(&verified);
            assert!(transfer::token_chain(&parsed) == expected_token_chain, 0);
            assert!(transfer::token_address(&parsed) == expected_token_address, 0);

            let decimals =
                state::coin_decimals<COIN_WRAPPED_7>(&token_bridge_state);

            assert!(transfer::raw_amount(&parsed, decimals) == expected_amount, 0);

            assert!(
                transfer::raw_relayer_fee(&parsed, decimals) == expected_relayer_fee,
                0
            );
            assert!(
                transfer::recipient_as_address(&parsed) == expected_recipient,
                0
            );
            assert!(transfer::recipient_chain(&parsed) == chain_id(), 0);

            // Clean up.
            transfer::destroy(parsed);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let payout =
            complete_transfer::complete_transfer<COIN_WRAPPED_7>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );
        assert!(coin::value(&payout) == expected_relayer_fee, 0);

        // TODO: Check for one event? `TransferRedeemed`.
        let _effects = test_scenario::next_tx(scenario, tx_relayer);

        // Check recipient's `Coin`.
        let received =
            test_scenario::take_from_address<Coin<COIN_WRAPPED_7>>(
                scenario,
                expected_recipient
            );
        assert!(coin::value(&received) == expected_recipient_amount, 0);

        // And check that the amount is the total wrapped supply.
        let registry = state::borrow_token_registry(&token_bridge_state);
        {
            let asset = token_registry::borrow_wrapped<COIN_WRAPPED_7>(registry);
            assert!(wrapped_asset::total_supply(asset) == expected_amount, 0);
        };

        // Clean up.
        coin::burn_for_testing(payout);
        coin::burn_for_testing(received);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    /// An end-to-end test for complete transfer wrapped with VAA.
    fun test_complete_transfer_wrapped_12_relayer_fee() {
        let transfer_vaa = dummy_message::encoded_transfer_vaa_wrapped_12_with_fee();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        coin_wrapped_12::init_and_register(scenario, coin_deployer);

        // Ignore effects.
        //
        // NOTE: `tx_relayer` != `expected_recipient`.
        assert!(expected_recipient != tx_relayer, 0);
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        // These will be checked later.
        let expected_relayer_fee = 1000;
        let expected_recipient_amount = 2000;
        let expected_amount = expected_relayer_fee + expected_recipient_amount;

        // Scope to allow immutable reference to `TokenRegistry`.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);
            let asset =
                token_registry::borrow_wrapped<COIN_WRAPPED_12>(registry);
            assert!(wrapped_asset::total_supply(asset) == 0, 0);

            // Verify transfer parameters.
            let parsed =
                transfer::deserialize(
                    wormhole::vaa::take_payload(
                        parse_and_verify_vaa(scenario, transfer_vaa)
                    )
                );

            let verified =
                token_registry::verified_asset<COIN_WRAPPED_12>(registry);
            let expected_token_chain = token_registry::token_chain(&verified);
            let expected_token_address =
                token_registry::token_address(&verified);
            assert!(transfer::token_chain(&parsed) == expected_token_chain, 0);
            assert!(transfer::token_address(&parsed) == expected_token_address, 0);

            let decimals =
                state::coin_decimals<COIN_WRAPPED_12>(&token_bridge_state);

            assert!(transfer::raw_amount(&parsed, decimals) == expected_amount, 0);

            assert!(
                transfer::raw_relayer_fee(&parsed, decimals) == expected_relayer_fee,
                0
            );
            assert!(
                transfer::recipient_as_address(&parsed) == expected_recipient,
                0
            );
            assert!(transfer::recipient_chain(&parsed) == chain_id(), 0);

            // Clean up.
            transfer::destroy(parsed);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let payout =
            complete_transfer::complete_transfer<COIN_WRAPPED_12>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );
        assert!(coin::value(&payout) == expected_relayer_fee, 0);

        // TODO: Check for one event? `TransferRedeemed`.
        let _effects = test_scenario::next_tx(scenario, tx_relayer);

        // Check recipient's `Coin`.
        let received =
            test_scenario::take_from_address<Coin<COIN_WRAPPED_12>>(
                scenario,
                expected_recipient
            );
        assert!(coin::value(&received) == expected_recipient_amount, 0);

        // And check that the amount is the total wrapped supply.
        let registry = state::borrow_token_registry(&token_bridge_state);
        {
            let asset = token_registry::borrow_wrapped<COIN_WRAPPED_12>(registry);
            assert!(wrapped_asset::total_supply(asset) == expected_amount, 0);
        };

        // Clean up.
        coin::burn_for_testing(payout);
        coin::burn_for_testing(received);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    /// An end-to-end test for complete transfer native with VAA. The encoded VAA
    /// specifies a nonzero fee, however the `recipient` should receive the full
    /// amount for self redeeming the transfer.
    fun test_complete_transfer_native_10_relayer_fee_self_redemption() {
        let transfer_vaa =
            dummy_message::encoded_transfer_vaa_native_with_fee();

        let (expected_recipient, _, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(expected_recipient);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        let custody_amount = 500000;
        coin_native_10::init_register_and_deposit(
            scenario,
            coin_deployer,
            custody_amount
        );

        // Ignore effects.
        test_scenario::next_tx(scenario, expected_recipient);

        let token_bridge_state = take_state(scenario);

        // NOTE: Although there is a fee encoded in the VAA, the relayer
        // shouldn't receive this fee. The `expected_relayer_fee` should
        // go to the recipient.
        //
        // These values will be used later.
        let expected_relayer_fee = 0;
        let encoded_relayer_fee = 100000;
        let expected_recipient_amount = 300000;
        let expected_amount = expected_relayer_fee + expected_recipient_amount;

        // Scope to allow immutable reference to `TokenRegistry`.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);
            let asset = token_registry::borrow_native<COIN_NATIVE_10>(registry);
            assert!(native_asset::custody(asset) == custody_amount, 0);

            // Verify transfer parameters.
            let parsed =
                transfer::deserialize(
                    wormhole::vaa::take_payload(
                        parse_and_verify_vaa(scenario, transfer_vaa)
                    )
                );

            let verified =
                token_registry::verified_asset<COIN_NATIVE_10>(registry);
            let expected_token_chain = token_registry::token_chain(&verified);
            let expected_token_address =
                token_registry::token_address(&verified);
            assert!(transfer::token_chain(&parsed) == expected_token_chain, 0);
            assert!(transfer::token_address(&parsed) == expected_token_address, 0);

            let decimals =
                state::coin_decimals<COIN_NATIVE_10>(&token_bridge_state);

            assert!(transfer::raw_amount(&parsed, decimals) == expected_amount, 0);
            assert!(
                transfer::raw_relayer_fee(&parsed, decimals) == encoded_relayer_fee,
                0
            );
            assert!(
                transfer::recipient_as_address(&parsed) == expected_recipient,
                0
            );
            assert!(transfer::recipient_chain(&parsed) == chain_id(), 0);

            // Clean up.
            transfer::destroy(parsed);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, expected_recipient);

        let payout =
            complete_transfer::complete_transfer<COIN_NATIVE_10>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );
        assert!(coin::value(&payout) == expected_relayer_fee, 0);

        // TODO: Check for one event? `TransferRedeemed`.
        let _effects = test_scenario::next_tx(scenario, expected_recipient);

        // Check recipient's `Coin`.
        let received =
            test_scenario::take_from_address<Coin<COIN_NATIVE_10>>(
                scenario,
                expected_recipient
            );
        assert!(coin::value(&received) == expected_recipient_amount, 0);

        // And check remaining amount in custody.
        let registry = state::borrow_token_registry(&token_bridge_state);
        let remaining = custody_amount - expected_amount;
        {
            let asset = token_registry::borrow_native<COIN_NATIVE_10>(registry);
            assert!(native_asset::custody(asset) == remaining, 0);
        };

        // Clean up.
        coin::burn_for_testing(payout);
        coin::burn_for_testing(received);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    #[expected_failure(abort_code = token_registry::E_CANONICAL_TOKEN_INFO_MISMATCH)]
    /// This test verifies that `complete_transfer` reverts when called with
    /// a native COIN_TYPE that's not encoded in the VAA.
    fun test_cannot_complete_transfer_native_invalid_coin_type() {
        let transfer_vaa =
            dummy_message::encoded_transfer_vaa_native_with_fee();

        let (_, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        let custody_amount_coin_10 = 500000;
        coin_native_10::init_register_and_deposit(
            scenario,
            coin_deployer,
            custody_amount_coin_10
        );

        // Register a second native asset.
        let custody_amount_coin_4 = 69420;
        coin_native_4::init_register_and_deposit(
            scenario,
            coin_deployer,
            custody_amount_coin_4
        );

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        // Scope to allow immutable reference to `TokenRegistry`. This verifies
        // that both coin types have been registered.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);

            // COIN_10.
            let coin_10 = token_registry::borrow_native<COIN_NATIVE_10>(registry);
            assert!(native_asset::custody(coin_10) == custody_amount_coin_10, 0);

            // COIN_4.
            let coin_4 = token_registry::borrow_native<COIN_NATIVE_4>(registry);
            assert!(native_asset::custody(coin_4) == custody_amount_coin_4, 0);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        // NOTE: this call should revert since the transfer VAA is for
        // a coin of type COIN_NATIVE_10. However, the `complete_transfer`
        // method is called using the COIN_NATIVE_4 type.
        let payout =
            complete_transfer::complete_transfer<COIN_NATIVE_4>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );

        // Clean up.
        coin::burn_for_testing(payout);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    #[expected_failure(abort_code = token_registry::E_CANONICAL_TOKEN_INFO_MISMATCH)]
    /// This test verifies that `complete_transfer` reverts when called with
    /// a wrapped COIN_TYPE that's not encoded in the VAA.
    fun test_cannot_complete_transfer_wrapped_invalid_coin_type() {
        let transfer_vaa = dummy_message::encoded_transfer_vaa_wrapped_12_with_fee();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        // Register both wrapped coin types (12 and 7).
        coin_wrapped_12::init_and_register(scenario, coin_deployer);
        coin_wrapped_7::init_and_register(scenario, coin_deployer);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        // NOTE: `tx_relayer` != `expected_recipient`.
        assert!(expected_recipient != tx_relayer, 0);

        let token_bridge_state = take_state(scenario);

        // Scope to allow immutable reference to `TokenRegistry`. This verifies
        // that both coin types have been registered.
        {
            let registry = state::borrow_token_registry(&token_bridge_state);

            let coin_12 =
                token_registry::borrow_wrapped<COIN_WRAPPED_12>(registry);
            assert!(wrapped_asset::total_supply(coin_12) == 0, 0);

            let coin_7 =
                token_registry::borrow_wrapped<COIN_WRAPPED_7>(registry);
            assert!(wrapped_asset::total_supply(coin_7) == 0, 0);
        };

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        // NOTE: this call should revert since the transfer VAA is for
        // a coin of type COIN_WRAPPED_12. However, the `complete_transfer`
        // method is called using the COIN_WRAPPED_7 type.
        let payout =
            complete_transfer::complete_transfer<COIN_WRAPPED_7>(
                &mut token_bridge_state,
                parsed,
                test_scenario::ctx(scenario)
            );

        // Clean up.
        coin::burn_for_testing(payout);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }

    #[test]
    #[expected_failure(abort_code = complete_transfer::E_TARGET_NOT_SUI)]
    /// This test verifies that `complete_transfer` reverts when a transfer is
    /// sent to the wrong target blockchain (chain ID != 21).
    fun test_cannot_complete_transfer_wrapped_12_invalid_target_chain() {
        let transfer_vaa =
            dummy_message::encoded_transfer_vaa_wrapped_12_invalid_target_chain();

        let (expected_recipient, tx_relayer, coin_deployer) = three_people();
        let my_scenario = test_scenario::begin(tx_relayer);
        let scenario = &mut my_scenario;

        // Set up contracts.
        let wormhole_fee = 350;
        set_up_wormhole_and_token_bridge(scenario, wormhole_fee);

        // Register foreign emitter on chain ID == 2.
        let expected_source_chain = 2;
        register_dummy_emitter(scenario, expected_source_chain);

        coin_wrapped_12::init_and_register(scenario, coin_deployer);

        // Ignore effects.
        //
        // NOTE: `tx_relayer` != `expected_recipient`.
        assert!(expected_recipient != tx_relayer, 0);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        let token_bridge_state = take_state(scenario);

        let parsed = parse_and_verify_vaa(scenario, transfer_vaa);

        // Ignore effects.
        test_scenario::next_tx(scenario, tx_relayer);

        // NOTE: this call should revert since the target chain encoded is
        // chain 69 instead of chain 21 (Sui).
        let payout = complete_transfer::complete_transfer<COIN_WRAPPED_12>(
            &mut token_bridge_state,
            parsed,
            test_scenario::ctx(scenario)
        );

        // Clean up.
        coin::burn_for_testing(payout);
        return_state(token_bridge_state);

        // Done.
        test_scenario::end(my_scenario);
    }
}

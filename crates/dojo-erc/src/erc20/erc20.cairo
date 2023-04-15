#[contract]
mod ERC20 {
    use array::ArrayTrait;
    use option::OptionTrait;
    use starknet::ContractAddress;
    use starknet::ContractAddressZeroable;
    use starknet::get_caller_address;
    use starknet::get_contract_address;
    use traits::Into;
    use zeroable::Zeroable;

    use dojo_core::storage::query::ContractAddressIntoQuery;
    use dojo_core::storage::query::Query;
    use dojo_core::storage::query::TupleSize2IntoPartitionedQuery;
    use dojo_core::storage::query::TupleSize1IntoPartitionedQuery;
    use dojo_core::interfaces::IWorldDispatcher;
    use dojo_core::interfaces::IWorldDispatcherTrait;

    use dojo_erc::erc20::components::Allowance;
    use dojo_erc::erc20::components::Balance;
    use dojo_erc::erc20::components::Supply;

    struct Storage {
        world_address: ContractAddress,
        token_name: felt252,
        token_symbol: felt252,
        token_decimals: u8,
    }

    #[event]
    fn Transfer(from: ContractAddress, to: ContractAddress, value: u256) {}

    #[event]
    fn Approval(owner: ContractAddress, spender: ContractAddress, value: u256) {}

    #[constructor]
    fn constructor(
        world: ContractAddress,
        name: felt252,
        symbol: felt252,
        decimals: u8,
        initial_supply: felt252,
        recipient: ContractAddress
    ) {
        world_address::write(world);
        token_name::write(name);
        token_symbol::write(symbol);
        token_decimals::write(decimals);

        if initial_supply != 0 {
            assert(recipient.is_non_zero(), 'ERC20: mint to the 0 address');
            let token = get_contract_address();
            let mut calldata = ArrayTrait::<felt252>::new();
            calldata.append(token.into());
            calldata.append(recipient.into());
            calldata.append(initial_supply);
            IWorldDispatcher { contract_address: world }.execute(
                'ERC20Mint', calldata.span()
            );
            Transfer(Zeroable::zero(), recipient, initial_supply.into());
        }
    }

    #[view]
    fn name() -> felt252 {
        token_name::read()
    }

    #[view]
    fn symbol() -> felt252 {
        token_symbol::read()
    }

    #[view]
    fn decimals() -> u8 {
        token_decimals::read()
    }

    #[view]
    fn total_supply() -> u256 {
        let query: Query = get_contract_address().into();
        let mut supply_raw = IWorldDispatcher { contract_address: world_address::read() }.entity(
            'Supply', query, 0_u8, 0_usize
        );
        let supply = serde::Serde::<Supply>::deserialize(ref supply_raw).unwrap();
        supply.amount.into()
    }

    #[view]
    fn balance_of(account: ContractAddress) -> u256 {
        let token = get_contract_address();
        let query: Query = (token.into(), (account.into(),)).into();        
        let mut balance_raw = IWorldDispatcher { contract_address: world_address::read() }.entity(
            'Balance', query, 0_u8, 0_usize
        );
        let balance = serde::Serde::<Balance>::deserialize(ref balance_raw).unwrap();
        balance.amount.into()
    }

    #[view]
    fn allowance(owner: ContractAddress, spender: ContractAddress) -> u256 {
        let token = get_contract_address();
        let query: Query = (token.into(), (owner.into(), spender.into())).into();
        let mut allowance_raw = IWorldDispatcher { contract_address: world_address::read() }.entity(
            'Allowance', query, 0_u8, 0_usize
        );
        let allowance = serde::Serde::<Allowance>::deserialize(ref allowance_raw).unwrap();
        allowance.amount.into()
    }

    #[external]
    fn approve(spender: ContractAddress, amount: u256) -> bool {
        assert(spender.is_non_zero(), 'ERC20: approve to 0 address');

        let token = get_contract_address();
        let owner = get_caller_address();
        let mut calldata = ArrayTrait::<felt252>::new();
        calldata.append(token.into());
        calldata.append(owner.into());
        calldata.append(spender.into());
        calldata.append(u256_as_felt252(amount));

        IWorldDispatcher { contract_address: world_address::read() }.execute(
            'ERC20Approve', calldata.span()
        );

        Approval(owner, spender, amount);

        true
    }

    // temporary, until TryInto of this is in corelib
    fn u256_as_felt252(val: u256) -> felt252 {
        val.low.into() + val.high.into() * 0x100000000000000000000000000000000
    }

    #[external]
    fn transfer(spender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
        transfer_internal(get_caller_address(), spender, amount);
        true
    }

    #[external]
    fn transfer_from(sender: ContractAddress, recipient: ContractAddress, amount: u256) -> bool {
        // TODO: spend_allowance(sender, get_caller_address(), amount);
        //       decrease the allowance in the system, if sender != caller
        //       that means we will need to exec the system with both in transfer_internal
        transfer_internal(sender, recipient, amount);
        true
    }

    fn transfer_internal(spender: ContractAddress, recipient: ContractAddress, amount: u256) {
        assert(recipient.is_non_zero(), 'ERC20: transfer to 0 address');

        let token = get_contract_address();
        let mut calldata = ArrayTrait::<felt252>::new();
        calldata.append(token.into());
        calldata.append(spender.into());
        calldata.append(recipient.into());
        calldata.append(u256_as_felt252(amount));

        IWorldDispatcher { contract_address: world_address::read() }.execute(
            'ERC20TransferFrom', calldata.span()
        );

        Transfer(spender, recipient, amount);
    }
}

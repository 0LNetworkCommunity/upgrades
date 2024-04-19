# Create a Upgrade Script

Sometimes we would like to adjust parameters of the network and not upgrade the underlying frameworks. For this we need to prepare and write an upgrade script.

## Build `libra-framework` binary

`cargo build --release -p libra-framework`

`sudo cp -f ~/libra-framework/target/debug/libra* ~/.cargo/bin/`

## Create Template Script

`libra-framework governance --script-dir <Script Dir>  --framework-local-dir ~/libra-framework/framework/ --only-make-template`

## Prepare Script

You will want to name the folders appropriately. We will use [UP-0002](../proposals/up-0002) as an example.

In this example we want to change the nomimal consensus reward due to a migration error at v7.0.0. 

### Folder Stucture

- patch_nominal_reward_migration_error
    - sources
        - patch_nominal_reward_migration_error.move

### Script

By default it prepares a `multi_step_proposal`. We dont need this as we are upgrading a parameter, not the framework.

#### Before

```
script {
  // THIS IS A TEMPLATE GOVERNANCE SCRIPT
  // you can generate this file with commandline tools: `libra-framework governance --output-dir --framework-local-dir`
  use diem_framework::diem_governance;
  use std::vector;

  fun main(proposal_id: u64){
      let next_hash = vector::empty();
      let _framework_signer = diem_governance::resolve_multi_step_proposal(proposal_id, @0000000000000000000000000000000000000000000000000000000000000001, next_hash);
  }
}
```


#### After

```
script {

  use diem_framework::diem_governance;
  use ol_framework::proof_of_fee;

  fun main(proposal_id: u64){
      let framework_signer = diem_governance::resolve(proposal_id, @0000000000000000000000000000000000000000000000000000000000000001);
      // Set the nominal_reward to the value prior to v7.0.1 hard fork
      proof_of_fee::genesis_migrate_reward(&framework_signer, 178204815);
  }
}
```

## Compile

`libra move compile --package-dir ~/upgrades/proposals/up-0002/patch_nominal_reward_migration_error/`

## Submit Proposal

follow instuctions [here](hot_upgrades.md#upgrade-ceremony)
use std::collections::HashMap;
use std::env::current_dir;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Context;
use cairo_lang_starknet::casm_contract_class::CasmContractClass;
use camino::Utf8PathBuf;
use clap::Args;
use dojo_lang::manifest::{self, Manifest};
use starknet::accounts::{Account, SingleOwnerAccount};
use starknet::core::chain_id;
use starknet::core::types::contract::{CompiledClass, SierraClass};
use starknet::core::types::FieldElement;
use starknet::providers::SequencerGatewayProvider;
use starknet::signers::{LocalWallet, SigningKey};
use url::Url;

#[derive(Args)]
pub struct DeployArgs {
    #[clap(help = "Source directory")]
    path: Option<Utf8PathBuf>,
}

#[tokio::main]
pub async fn run(args: DeployArgs) -> anyhow::Result<()> {
    let source_dir = match args.path {
        Some(path) => {
            if path.is_absolute() {
                path
            } else {
                let mut current_path = current_dir().unwrap();
                current_path.push(path);
                Utf8PathBuf::from_path_buf(current_path).unwrap()
            }
        }
        None => Utf8PathBuf::from_path_buf(current_dir().unwrap()).unwrap(),
    };

    // Devnet only supports RPC for Cairo 1 right now.
    let rpc = SequencerGatewayProvider::new(
        Url::parse("http://127.0.0.1:5050/gateway").unwrap(),
        Url::parse("http://127.0.0.1:5050/feeder_gateway").unwrap(),
    );
    // let rpc =
    //     JsonRpcClient::new(HttpTransport::new(Url::parse("http://127.0.0.1:5050/rpc").unwrap()));

    // Read the directory
    let entries = fs::read_dir(source_dir.join("target/release")).unwrap_or_else(|error| {
        panic!("Problem reading source directory: {:?}", error);
    });

    let local_manifest = Manifest::load_from_path(source_dir.join("target/release/manifest.json"))?;

    let signer = LocalWallet::from(SigningKey::from_secret_scalar(
        FieldElement::from_hex_be("0x5d4fb5e2c807cd78ac51675e06be7099").unwrap(),
    ));
    let address = FieldElement::from_hex_be(
        "0x5f6fd2a43f4bce1bdfb2d0e9212d910227d9f67cf1425f2a9ceae231572c643",
    )
    .unwrap();
    let account = SingleOwnerAccount::new(rpc, signer, address, chain_id::TESTNET);

    let mut artifact_paths = HashMap::new();
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let file_name_str = file_name.to_string_lossy();
        if file_name_str == "manifest.json" || !file_name_str.ends_with(".json") {
            continue;
        }

        let name = file_name_str.split('_').last().unwrap().trim_end_matches(".json").to_string();
        println!("Found artifact: {}", name);
        artifact_paths.insert(name, entry.path());
    }

    assert!(
        declare(account.clone(), "World".into(), artifact_paths.get("World").unwrap()).await?
            == local_manifest.world.unwrap(),
    );
    declare(account.clone(), "Executor".into(), artifact_paths.get("Executor").unwrap()).await?;
    declare(account, "Indexer".into(), artifact_paths.get("Indexer").unwrap()).await?;

    Ok(())
}

async fn declare(
    account: SingleOwnerAccount<SequencerGatewayProvider, LocalWallet>,
    name: String,
    path: &PathBuf,
) -> anyhow::Result<FieldElement> {
    let contract_class = serde_json::from_reader(fs::File::open(path.clone()).unwrap())
        .unwrap_or_else(|error| {
            panic!("Problem parsing {} artifact: {:?}", name, error);
        });
    let contract_artifact: SierraClass =
        serde_json::from_reader(std::fs::File::open(path).unwrap()).unwrap();

    let casm_contract = CasmContractClass::from_contract_class(contract_class, true)
        .with_context(|| "Compilation failed.")?;
    let res = serde_json::to_string_pretty(&casm_contract)
        .with_context(|| "Casm contract Serialization failed.")?;

    let compiled_class: CompiledClass =
        serde_json::from_str(res.as_str()).unwrap_or_else(|error| {
            panic!("Problem parsing {} artifact: {:?}", name, error);
        });
    let compiled_class_hash = compiled_class.class_hash().unwrap();

    // We need to flatten the ABI into a string first
    let flattened_class = contract_artifact.flatten().unwrap();

    let result = account
        .declare(Arc::new(flattened_class), compiled_class_hash)
        .send()
        .await
        .unwrap_or_else(|error| {
            panic!("Problem deploying {} artifact: {:?}", name, error);
        });

    println!("Declared {} to {:?}", name, result);

    Ok(result.class_hash.unwrap())
}

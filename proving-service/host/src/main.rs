use methods::{GUEST_PROOFING_LOGIC_ELF, GUEST_PROOFING_LOGIC_ID};

use base64::{engine::general_purpose, Engine as _};
use chrono::Local;
use env_helper::process_and_write_proofs;
use log::info;
use proving_service_core::product_footprint::ProductProof;
use proving_service_core::proofing_document::*;
use rdkafka::config::ClientConfig;
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::message::Message;
use rdkafka::producer::{FutureProducer, FutureRecord};
use risc0_zkvm::{default_prover, ExecutorEnv};
use serde_path_to_error::deserialize;
use std::fs::File;
use std::io::Write;
use tokio::time::Duration;
#[cfg(test)]
use tokio::time::Instant;

use crate::benchmarking::RunDataCollector;

mod benchmarking;
mod env_helper;
mod sig_verifier;

const TOPIC_IN: &str = "shipments";
const TOPIC_OUT: &str = "pcf-results";
const DEBUG: bool = false;

async fn process_payload(payload_str: &str) -> Option<ProductProof> {
    // println!("Rohdaten der Nachricht: {}", payload_str);
    // Versuch direkt zu parsen (raw JSON)
    if let Ok(proof_response) = try_handle_raw_json(payload_str).await {
        return Some(proof_response);
    }

    // Falls das fehlschlägt, versuche es als stringifizierten JSON-String zu entpacken
    let inner_json_str: String = match serde_json::from_str(payload_str) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("Fehler beim Entpacken des JSON-Strings: {}", e);
            return None;
        }
    };

    try_handle_raw_json(&inner_json_str).await.ok()
}

async fn try_handle_raw_json(shipments_json: &str) -> Result<ProductProof, ()> {
    match handle_kafka_message(shipments_json).await {
        Some(resp) => Ok(resp),
        None => Err(()),
    }
}

#[tokio::main]
async fn main() {
    let brokers = std::env::var("KAFKA_BROKER").unwrap_or_else(|_| "localhost:9092".to_string());
    env_logger::init();

    let consumer: StreamConsumer = ClientConfig::new()
        .set("bootstrap.servers", &brokers)
        .set("security.protocol", "PLAINTEXT")
        .set("group.id", "risc0-pcf-kafka-group")
        .set("auto.offset.reset", "earliest")
        .set("enable.auto.commit", "true")
        .set("auto.commit.interval.ms", "5000")
        .set("message.max.bytes", "52428800")
        .set("max.poll.interval.ms", "1800000")
        .create()
        .expect("Consumer creation failed");

    consumer.subscribe(&[TOPIC_IN]).unwrap();

    let producer: FutureProducer = ClientConfig::new()
        .set("bootstrap.servers", &brokers)
        .set("security.protocol", "PLAINTEXT")
        .set("message.max.bytes", "52428800")
        .create()
        .expect("Producer creation failed");

    loop {
        match consumer.recv().await {
            Ok(message) => match message.payload_view::<str>() {
                Some(Ok(payload_str)) => {
                    if let Some(proof_response) = process_payload(payload_str).await {
                        let result_json = serde_json::to_string(&proof_response)
                            .expect("Failed to serialize proof_response");
                        let record = FutureRecord::to(TOPIC_OUT)
                            .payload(&result_json)
                            .key("some-key");
                        let _ = producer.send(record, Duration::from_secs(10)).await;
                    } else {
                        info!("Ungültige Nachricht wurde ignoriert.");
                    }
                }
                Some(Err(e)) => eprintln!("Payload UTF-8 error: {}", e),
                None => eprintln!("No payload"),
            },
            Err(e) => eprintln!("Kafka error receiving message: {:?}", e),
        }
    }
}

async fn main_proving_logic(
    mut proving_document: ProofingDocument,
    _collector: Option<&mut RunDataCollector>,
) -> Option<ProductProof> {
    #[cfg(test)] // Benchmarking
    let total_start_time = Instant::now();

    println!(
        "Received proving document with ID: {}",
        proving_document.productFootprint.id
    );
    println!(
        "From Company: {}",
        proving_document.productFootprint.companyName
    );

    // Take away the proof extension from the proving document
    let proof_vec = proving_document.proof;
    proving_document.proof = Vec::new();

    // Build the ExecutorEnv
    let mut builder = ExecutorEnv::builder();
    let executor_env_builder = builder
        .write(&proving_document)
        .expect("Failed to write proving_document to ExecutorEnv builder");

    process_and_write_proofs(&proof_vec, executor_env_builder);

    let env = executor_env_builder
        .build()
        .expect("Failed to build ExecutorEnv!");

    // Start the proving process
    let prover = default_prover();
    println!("ELF size: {}", GUEST_PROOFING_LOGIC_ELF.len());

    #[cfg(test)] // Benchmarking
    let proof_start_time = Instant::now();

    let prove_info = match prover.prove(env, GUEST_PROOFING_LOGIC_ELF) {
        Ok(info) => info,
        Err(e) => {
            eprintln!("Error while proving: {}", e);
            return None;
        }
    };

    #[cfg(test)] // Benchmarking
    let duration = proof_start_time.elapsed();

    let receipt = prove_info.receipt;

    let (journal_output, _serialized_sig_containers): (f64, Vec<u8>) =
        match receipt.journal.decode() {
            Ok(data) => data,
            Err(e) => {
                eprintln!("Failed to decode journal: {}", e);
                return None;
            }
        };

    if let Err(e) = receipt.verify(GUEST_PROOFING_LOGIC_ID) {
        eprintln!("Receipt verification failed: {}", e);
        return None;
    }

    let receipt_bytes = match bincode::serialize(&receipt) {
        Ok(bytes) => bytes,
        Err(e) => {
            eprintln!("Failed to serialize receipt: {}", e);
            return None;
        }
    };
    let encoded_receipt = general_purpose::STANDARD.encode(receipt_bytes);

    println!("PCF Value from Journal: {}", journal_output);

    println!(
        "[{}]: Handed over response\n",
        Local::now().format("%H:%M:%S").to_string()
    );

    let proof_respone = ProductProof {
        productFootprintId: proving_document.productFootprint.id,
        proofReceipt: encoded_receipt,
        proofReference: "123".to_string(),
        pcf: journal_output,
        imageId: hex::encode(bytemuck::cast_slice(&GUEST_PROOFING_LOGIC_ID)),
    };

    if DEBUG {
        // Write Output to file (for debugging purposes)
        let json_string = serde_json::to_string_pretty(&proof_respone).ok()?;
        let mut file = File::create("latest_output.json").ok()?;
        file.write_all(&json_string.as_bytes()).ok()?;
    }

    #[cfg(test)] // Benchmarking
    {
        let total_duration = total_start_time.elapsed();
        _collector
            .unwrap()
            .set_total_time(total_duration.as_secs())
            .set_proof_time(duration.as_secs())
            .set_cycles(&prove_info.stats);
    }

    Some(proof_respone)
}

async fn parse_proving_document(json_content: &str) -> Option<ProofingDocument> {
    let mut de = serde_json::Deserializer::from_str(json_content);
    match deserialize(&mut de) {
        Ok(proving_document) => Some(proving_document),
        Err(e) => {
            eprintln!(
                "Failed to deserialize message at path '{}': {}",
                e.path(),
                e
            );
            None
        }
    }
}

async fn handle_kafka_message(shipments_json: &str) -> Option<ProductProof> {
    println!(
        "[{}]: ----------- Received message -----------",
        Local::now().format("%H:%M:%S").to_string()
    );

    let proving_document = parse_proving_document(shipments_json)
        .await
        .expect("Failed to parse proving document");

    let product_proof = main_proving_logic(proving_document, None).await;

    product_proof
}

#[cfg(test)]
mod tests {
    use crate::{
        benchmarking::{create_numbered_file, DocumentGenerator, RunDataCollector},
        main_proving_logic, parse_proving_document,
    };

    use super::handle_kafka_message;
    use proving_service_core::{
        product_footprint::ProductProof, proofing_document::ProofingDocument,
    };
    use rand::Rng;
    use rdkafka::{consumer::{Consumer as _, StreamConsumer}, producer::{FutureProducer, FutureRecord}, ClientConfig, Message as _};
    use std::{
        env,
        fs::{self, File},
        io::Write, time::Duration,
    };
    use tokio;

    const DEV_MODE: &str = "false";

    #[tokio::test]
    async fn kafka_service() {
        const TOPIC_OUT: &str = "pcf-results";
        const TOPIC_IN: &str = "shipments";
        let brokers = std::env::var("KAFKA_BROKER").unwrap_or_else(|_| "localhost:9092".to_string());
        let consumer: StreamConsumer = ClientConfig::new()
            .set("bootstrap.servers", &brokers)
            .set("security.protocol", "PLAINTEXT")
            .set("group.id", "risc0-pcf-kafka-group")
            .set("auto.offset.reset", "earliest")
            .set("enable.auto.commit", "true")
            .set("auto.commit.interval.ms", "5000")
            .set("message.max.bytes", "104857600")
            .create()
            .expect("Consumer creation failed");

        consumer.subscribe(&[TOPIC_OUT]).unwrap();

        let producer: FutureProducer = ClientConfig::new()
            .set("bootstrap.servers", &brokers)
            .set("security.protocol", "PLAINTEXT")
            .set("message.max.bytes", "104857600")
            .create()
            .expect("Producer creation failed");
        let json_content = fs::read_to_string("../benchmarks/documents/comp_document_21.json");
        let binding = json_content.unwrap();
        let record = FutureRecord::to(TOPIC_OUT)
                            .payload(&binding)
                            .key("some-key");
        let _ = producer.send(record, Duration::from_secs(10)).await;

        loop {
        match consumer.recv().await {
            Ok(message) => match message.payload_view::<str>() {
                Some(Ok(payload_str)) => {
                    println!("{}", payload_str);
                }
                Some(Err(e)) => eprintln!("Payload UTF-8 error: {}", e),
                None => eprintln!("No payload"),
            },
            Err(e) => eprintln!("Kafka error receiving message: {:?}", e),
        }
    }
    }

    #[tokio::test]
    // Test: 3 TCEs; 1 Sig; 0 proofs
    async fn test_3_1_0() -> Result<(), Box<dyn std::error::Error>> {
        let json_content = fs::read_to_string("../benchmarks/documents/comp_document_5.json")?;

        // Call kafka handler
        let _resp: ProductProof = handle_kafka_message(&json_content)
            .await
            .expect("kafka_handler_failed");
        // If we reach here, resp is already a ProductProof, so no need to check is_some
        Ok(())
    }

    #[tokio::test]
    // Test: 3 TCEs; 1 Sig; 1 proofs
    async fn test_3_1_1() -> Result<(), Box<dyn std::error::Error>> {
        let json_content = fs::read_to_string("json-examples/test_3_1_1.json")?;

        // Call kafka handler
        let _resp: ProductProof = handle_kafka_message(&json_content)
            .await
            .expect("kafka_handler_failed");
        // If we reach here, resp is already a ProductProof, so no need to check is_some
        Ok(())
    }

    #[ignore]
    #[tokio::test]
    async fn bench_composition() -> Result<(), Box<dyn std::error::Error>> {
        env::set_var("RISC0_DEV_MODE", DEV_MODE);
        let n: u32 = 20;

        let mut generator = DocumentGenerator::new();
        let mut collector = RunDataCollector::new("bench_composition");
        let mut response: Option<ProductProof> = None;

        for _ in 0..n {
            let mut proving_document: ProofingDocument;

            proving_document = generator.generate_proving_document_random().clone();
            if let Some(ref resp) = response {
                proving_document.proof.push(resp.clone());
            }

            match create_numbered_file(
                std::path::Path::new("../benchmarks/documents/comp_document"),
                "json",
            ) {
                Ok(path) => {
                    let mut file = File::create(&path)?;
                    if let Some(json_string) = serde_json::to_string_pretty(&proving_document).ok()
                    {
                        file.write_all(json_string.as_bytes()).ok();
                    }
                }
                Err(_) => {
                    eprintln!("Failed to create proving document");
                }
            }

            collector.start_new_run().set_input(&proving_document);
            response = Some(
                main_proving_logic(proving_document.clone(), Some(&mut collector))
                    .await
                    .expect("Failed main logic"),
            );
            collector.set_output(response.as_ref().unwrap());
            collector.print_current_run();
        }
        collector
            .write_to_csv()
            .expect("Failed to write metrics to CSV");
        Ok(())
    }

    #[ignore]
    #[tokio::test]
    async fn bench_proofaggregation() -> Result<(), Box<dyn std::error::Error>> {

        let mut rng = rand::thread_rng();
        env::set_var("RISC0_DEV_MODE", DEV_MODE);
        let n: u32 = 20;


        let mut generator = DocumentGenerator::new();
        let mut collector = RunDataCollector::new("bench_proof_aggregation");
        let mut response: Option<ProductProof> = None;

        let mut tocs = 0;
        let mut hocs = 0;

        // let mut proving_document = generator.generate_proving_document(0, 0);

        for i in 0..20 {

            let n: u32 = rng.gen_range(1..5);
            let m: u32 = n.saturating_sub(rng.gen_range(0..3));
            tocs = tocs + n;
            hocs = hocs + m;
            // let path = format!("../benchmarks/documents/comp_document_{}.json", i + 2);
            // let json_content = fs::read_to_string(path)?;
            // let mut proving_document = parse_proving_document(&json_content)
            //     .await
            //     .expect("Failed to parse proving document");

            // proving_document.proof.clear();
            // collector.start_new_run().set_input(&proving_document);
            // response = main_proving_logic(proving_document.clone(), Some(&mut collector))
            //     .await;
            // collector.set_output(response.as_ref().unwrap());
            // collector.print_current_run();
        }

        let mut proving_document = generator.generate_proving_document(tocs, hocs);
        collector.start_new_run().set_input(&proving_document);
        response = main_proving_logic(proving_document.clone(), Some(&mut collector))
            .await;
        collector.set_output(response.as_ref().unwrap());
        collector.print_current_run();

        collector
            .write_to_csv()
            .expect("Failed to write metrics to CSV");
        Ok(())


        // let json_content = fs::read_to_string("json-examples/test_3_1_1.json")?;
        // let mut proving_document = parse_proving_document(&json_content)
        //     .await
        //     .expect("Failed to parse proving document");

        // for _ in 0..9 {
        //     proving_document
        //         .proof
        //         .push(proving_document.proof[0].clone())
        // }

        // let _response = main_proving_logic(proving_document.clone(), None)
        //     .await
        //     .expect("Failed main logic");

        // Ok(())
    }

    #[ignore]
    #[tokio::test]
    async fn bench_aggregation() -> Result<(), Box<dyn std::error::Error>> {
        env::set_var("RISC0_DEV_MODE", DEV_MODE);
        let n: u32 = 10;

        let mut collector = RunDataCollector::new("bench_aggregation");
        let mut response: Option<ProductProof> = None;
        let mut generator = DocumentGenerator::new();
        let mut proofs : Vec<ProductProof> = Vec::new();
        //let mut proving_document;

        let mut blank_proving_document = generator.generate_proving_document(0, 0);
        let mut docs: Vec<ProofingDocument> = Vec::new();
        docs.push(generator.generate_proving_document(4, 2));
        docs.push(generator.generate_proving_document(2, 1));
        docs.push(generator.generate_proving_document(1, 1));
        docs.push(generator.generate_proving_document(4, 2));
        docs.push(generator.generate_proving_document(1, 0));
        docs.push(generator.generate_proving_document(1, 1));
        docs.push(generator.generate_proving_document(4, 2));
        docs.push(generator.generate_proving_document(2, 0));
        docs.push(generator.generate_proving_document(1, 0));
        docs.push(generator.generate_proving_document(4, 4));
        docs.push(generator.generate_proving_document(4, 3));
        docs.push(generator.generate_proving_document(2, 0));
        docs.push(generator.generate_proving_document(4, 0));
        docs.push(generator.generate_proving_document(2, 0));
        docs.push(generator.generate_proving_document(1, 0));
        docs.push(generator.generate_proving_document(3, 1));
        docs.push(generator.generate_proving_document(2, 2));
        docs.push(generator.generate_proving_document(1, 1));
        docs.push(generator.generate_proving_document(1, 1));
        docs.push(generator.generate_proving_document(3, 2));

        for i in 0..docs.len() {
            let proving_document = &docs[i];
            collector.start_new_run().set_input(&proving_document);
            response = main_proving_logic(proving_document.clone(), Some(&mut collector))
                .await;
            collector.set_output(response.as_ref().unwrap());
            collector.print_current_run();
            blank_proving_document.proof.push(response.unwrap().clone());
        }
        

        match create_numbered_file(
            std::path::Path::new("../benchmarks/documents/aggr_document"),
            "json",
        ) {
            Ok(path) => {
                let mut file = File::create(&path)?;
                if let Some(json_string) = serde_json::to_string_pretty(&blank_proving_document).ok() {
                    file.write_all(json_string.as_bytes()).ok();
                }
            }
            Err(_) => {
                eprintln!("Failed to create proving document");
            }
        }

        collector.start_new_run().set_input(&blank_proving_document);
        response = main_proving_logic(blank_proving_document.clone(), Some(&mut collector))
            .await;
        collector.set_output(response.as_ref().unwrap());
        collector.print_current_run();
        proofs.push(response.unwrap().clone());

        collector
            .write_to_csv()
            .expect("Failed to write metrics to CSV");
        Ok(())
    }

    
}

import os
import json
import subprocess  # ◄ This lets Python run terminal commands for you!
from dotenv import load_dotenv

load_dotenv()

# --- SUI CONTRACT CONFIGURATION ---
PACKAGE_ID = "0x90e5be781d448e53b9d28f641269047a8eb3d82cc368e421d8cc78c23da34b68"
MODULE_NAME = "trade"
ORACLE_CAP_ID = "0x2e118287e960a6aa84bc7cf22d0ba1c467643a456126d7ffdedff68d1e5ed098"
CLOCK_OBJECT_ID = "0x6"

# HOLDER
TARGET_ESCROW_ID = "0xc18b4104b82bb9fdd5c4243607a3fec4fc03e66d21fec2a806aa5b9b53cf1e4f"

def verify_real_world_data(tracking_id, bill_of_lading):
    print(f"\n🔍 [ORACLE BRAIN] Checking real-world logistics databases...")
    print(f"-> Tracking ID submitted: {tracking_id}")
    print(f"-> Bill of Lading submitted: {bill_of_lading}")
    
    if "DHL" in tracking_id and "BOL" in bill_of_lading:
        print("✅ [VERIFICATION SUCCESS]: Shipping IDs match and cargo data is authentic!")
        return True
    else:
        print("❌ [VERIFICATION FAILED]: Document mismatch! Fraud or cargo data invalid.")
        return False

def execute_on_chain_payout(escrow_id, bol, tracking):
    """
    Automates the native 'sui client call' terminal command directly via Python.
    """
    print(f"\n🚀 [HYBRID GATEWAY] Initiating live transaction for Order: {escrow_id}...")
    
    # Constructing the exact terminal command line string
    command = [
        "sui", "client", "call",
        "--package", PACKAGE_ID,
        "--module", MODULE_NAME,
        "--function", "oracle_releases_phase_1",
        "--args", 
        ORACLE_CAP_ID,
        escrow_id,
        bol,
        tracking,
        "",  # Empty string for inspection certificate argument
        CLOCK_OBJECT_ID,
        "--gas-budget", "20000000"
    ]
    
    try:
        # Running the command in your Ubuntu terminal automatically
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        print("🎉 [BLOCKCHAIN SUCCESS] Transaction pushed to Testnet successfully!")
        print(result.stdout)
    except subprocess.CalledProcessError as e:
        print("❌ [BLOCKCHAIN ERROR] The transaction transaction was rejected or failed:")
        print(e.stderr)

if __name__ == "__main__":
    print("--- Sui Python Hybrid Oracle Simulator Running ---")
    
    input_tracking = "DHL-TRACK-9988"
    input_bill_of_lading = "BOL-GARMENT-9988"
    
    # 1. Run the logistics verification engine
    is_data_valid = verify_real_world_data(input_tracking, input_bill_of_lading)
    
    # 2. If data is secure, execute the terminal call automation
    if is_data_valid:
        if "YOUR_LIVE" in TARGET_ESCROW_ID:
            print("\n🛑 [NOTICE]: Verification passed! To push this live on-chain, please replace 'TARGET_ESCROW_ID' with a live active Escrow object ID inside the script.")
        else:
            execute_on_chain_payout(TARGET_ESCROW_ID, input_bill_of_lading, input_tracking)
    else:
        print("\n🛑 Status: HALTED. Fraudulent information blocked.")
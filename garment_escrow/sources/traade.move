module garment_escrow::trade {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance}; 
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};

    // ERROR CONSTANTS
    const EAlreadyReleased: u64 = 0;
    const ENotAuthorized: u64 = 1;
    const ENotTheBuyer: u64 = 2;
    const EInvalidBufferDays: u64 = 3;         
    const EInvalidMilestoneState: u64 = 4;     
    const ETimeBufferNotExpired: u64 = 5;      
    const EMissingRequiredDocuments: u64 = 6;
    const EOrderNotDisputed: u64 = 7;
    const EOrderNotCompleted: u64 = 8;

    // RISK MANAGEMENT LEVELS
    const TRUST_LEVEL_MANUAL: u8 = 1;      // Tier 1: 100% manual payout after manual document check
    const TRUST_LEVEL_AUTOMATED: u8 = 2;   // Tier 2: 70/30 split via automated Python validation + Buffer
    const TRUST_LEVEL_INSPECTION: u8 = 3;  // Tier 3: 70/30 split + 3rd Party Inspection Certificate + Buffer
    
    // ESCROW STATES
    const STATE_LOCKED: u8 = 10;               // Funds safely held in vault
    const STATE_SHIPPED_70_RELEASED: u8 = 11;  // 70% released (or tracking established)
    const STATE_FULLY_COMPLETED: u8 = 12;      // 100% funds cleared, deal finalized
    const STATE_DISPUTED: u8 = 13;             // Frozen due to document mismatch or failed inspection

    // ESCROW DATA STRUCTURE
    public struct EscrowOrder has key {
        id: UID,
        buyer: address,
        seller: address,
        amount: Balance<SUI>,           
        security_level: u8,        
        milestone_state: u8,       
        buffer_days: u64,              // Fixed at initialization (1 to 10 days)
        shipped_timestamp: u64,        // Locked when Phase 1 executes
        is_completed: bool,
        // On-chain cryptographic hashes/IDs proving documentation exists
        bill_of_lading_id: vector<u8>,
        tracking_id: vector<u8>,
        inspection_certificate_id: vector<u8>, // Enforced strictly for Tier 3
        customs_invoice_url: vector<u8>,       // Hosted document link for DApp downloads
    }

    // Capability for your Python backend management script
    public struct OracleCapability has key, store {
        id: UID,
    }

    fun init(ctx: &mut TxContext) {
        let oracle_cap = OracleCapability {
            id: object::new(ctx),
        };
        transfer::public_transfer(oracle_cap, ctx.sender());
    }

    // 1. BUYER INITIATES THE DEAL & FIXES THE BUFFER PARAMETERS PERMANENTLY
    public entry fun create_order(
        seller: address,
        deposit: Coin<SUI>,
        chosen_security_level: u8,
        custom_buffer_days: u64,
        customs_invoice_url: vector<u8>, // Provided so DApp users can fetch trade paperwork
        ctx: &mut TxContext 
    ) {
        // Enforce 1-10 days rule for any automated or high-risk split contracts
        if (chosen_security_level == TRUST_LEVEL_AUTOMATED || chosen_security_level == TRUST_LEVEL_INSPECTION) {
            assert!(custom_buffer_days >= 1 && custom_buffer_days <= 10, EInvalidBufferDays);
        };

        let order = EscrowOrder {
            id: object::new(ctx),
            buyer: ctx.sender(),
            seller,
            amount: coin::into_balance(deposit), 
            security_level: chosen_security_level,
            milestone_state: STATE_LOCKED,
            buffer_days: custom_buffer_days,
            shipped_timestamp: 0,
            is_completed: false,
            bill_of_lading_id: vector::empty(),
            tracking_id: vector::empty(),
            inspection_certificate_id: vector::empty(),
            customs_invoice_url,
        };
        transfer::share_object(order);
    }

    // 2. PHASE 1 EXECUTION ENGINE (THE 70% OR 100% UNLOCK ROUTE)
    fun execute_phase_1(
        order: &mut EscrowOrder, 
        bill_of_lading: vector<u8>,
        tracking: vector<u8>,
        inspection_cert: vector<u8>,
        clock: &Clock, 
        ctx: &mut TxContext
    ) {
        assert!(order.milestone_state == STATE_LOCKED, EInvalidMilestoneState);
        assert!(!order.is_completed, EAlreadyReleased);
        
        // BASELINE RULE: Bill of Lading and Tracking ID must be present for ALL tiers
        assert!(!vector::is_empty(&bill_of_lading), EMissingRequiredDocuments);
        assert!(!vector::is_empty(&tracking), EMissingRequiredDocuments);

        // HIGH-RISK TIER 3 RULE: Third-party quality inspection certificate is mandatory
        if (order.security_level == TRUST_LEVEL_INSPECTION) {
            assert!(!vector::is_empty(&inspection_cert), EMissingRequiredDocuments);
        };

        // Write documents to the ledger state permanently
        order.bill_of_lading_id = bill_of_lading;
        order.tracking_id = tracking;
        order.inspection_certificate_id = inspection_cert;

        let total_value = balance::value(&order.amount);

        if (order.security_level == TRUST_LEVEL_MANUAL) {
            // Tier 1: Straight 100% fast clearance to seller based on manual approval
            order.milestone_state = STATE_FULLY_COMPLETED;
            order.is_completed = true;

            let split_bal = balance::split(&mut order.amount, total_value);
            let cash_payout = coin::from_balance(split_bal, ctx);
            transfer::public_transfer(cash_payout, order.seller);
        } else {
            // Tier 2 & 3: Lock down shipping time and process the 70% milestone release
            order.milestone_state = STATE_SHIPPED_70_RELEASED;
            order.shipped_timestamp = clock::timestamp_ms(clock);

            let amount_70_percent = (total_value * 70) / 100;
            let split_bal = balance::split(&mut order.amount, amount_70_percent);
            let cash_payout = coin::from_balance(split_bal, ctx);
            transfer::public_transfer(cash_payout, order.seller);
        };
    }

    // 3. PHASE 2 EXECUTION ENGINE (THE REMAINING 30% DEFERRED PAYOUT)
    fun execute_phase_2(order: &mut EscrowOrder, clock: &Clock, ctx: &mut TxContext) {
        assert!(order.milestone_state == STATE_SHIPPED_70_RELEASED, EInvalidMilestoneState);
        assert!(!order.is_completed, EAlreadyReleased);

        // Rigorous time-buffer enforcement using the immutable timeline set at step 1
        let buffer_in_ms = order.buffer_days * 86400 * 1000;
        let current_time = clock::timestamp_ms(clock);
        assert!(current_time >= (order.shipped_timestamp + buffer_in_ms), ETimeBufferNotExpired);
        
        order.milestone_state = STATE_FULLY_COMPLETED;
        order.is_completed = true;

        let remaining_value = balance::value(&order.amount);
        let split_bal = balance::split(&mut order.amount, remaining_value);
        let final_30_percent = coin::from_balance(split_bal, ctx);

        transfer::public_transfer(final_30_percent, order.seller);
    }

    // --- API GATEWAYS FOR PYTHON AUTOMATION SYSTEM (TIERS 2 & 3) ---

    public entry fun oracle_releases_phase_1(
        _: &OracleCapability,
        order: &mut EscrowOrder,
        bill_of_lading: vector<u8>,
        tracking: vector<u8>,
        inspection_cert: vector<u8>, // Passed from script if Tier 3, can be empty for Tier 2
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(order.security_level == TRUST_LEVEL_AUTOMATED || order.security_level == TRUST_LEVEL_INSPECTION, ENotAuthorized);
        execute_phase_1(order, bill_of_lading, tracking, inspection_cert, clock, ctx);
    }

    public entry fun oracle_releases_phase_2(
        _: &OracleCapability,
        order: &mut EscrowOrder,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(order.security_level == TRUST_LEVEL_AUTOMATED || order.security_level == TRUST_LEVEL_INSPECTION, ENotAuthorized);
        execute_phase_2(order, clock, ctx);
    }

    // --- API GATEWAYS FOR MANUAL USER INTERFACE (TIER 1) ---

    public entry fun buyer_manual_verify_and_release(
        order: &mut EscrowOrder,
        bill_of_lading: vector<u8>,
        tracking: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(order.security_level == TRUST_LEVEL_MANUAL, ENotAuthorized);
        assert!(ctx.sender() == order.buyer, ENotTheBuyer);
        // Manual tier doesn't need third-party certs, send empty vector
        execute_phase_1(order, bill_of_lading, tracking, vector::empty(), clock, ctx);
    }

    // --- SYSTEM CONFLICT & ESCAPE HATCH MANAGEMENT ---

    public entry fun oracle_trigger_dispute(
        _: &OracleCapability,
        order: &mut EscrowOrder,
    ) {
        assert!(order.security_level == TRUST_LEVEL_AUTOMATED || order.security_level == TRUST_LEVEL_INSPECTION, ENotAuthorized);
        assert!(order.milestone_state == STATE_LOCKED, EInvalidMilestoneState);
        order.milestone_state = STATE_DISPUTED;
    }

    public entry fun oracle_reject_and_refund_buyer(
        _: &OracleCapability,
        order: &mut EscrowOrder,
        ctx: &mut TxContext
    ) {
        assert!(order.milestone_state == STATE_DISPUTED, EOrderNotDisputed);
        order.is_completed = true;
        
        let total_funds = balance::value(&order.amount);
        let split_bal = balance::split(&mut order.amount, total_funds);
        let refund_coin = coin::from_balance(split_bal, ctx);
        transfer::public_transfer(refund_coin, order.buyer);
    }

    // Garbage collection for completing orders
    public entry fun clean_completed_order(order: EscrowOrder) {
        assert!(order.is_completed, EOrderNotCompleted);
        let EscrowOrder { 
            id, buyer: _, seller: _, amount, security_level: _, milestone_state: _, 
            buffer_days: _, shipped_timestamp: _, is_completed: _, bill_of_lading_id: _, 
            tracking_id: _, inspection_certificate_id: _, customs_invoice_url: _ 
        } = order;
        
        object::delete(id);
        balance::destroy_zero(amount);
    }
}
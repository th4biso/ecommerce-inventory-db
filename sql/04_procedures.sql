-- =====================================================================
--  Stored procedures for the two operations that change stock
--
--  Both run inside a transaction and lock the inventory row they change
--  (SELECT ... FOR UPDATE), so two orders for the last unit in stock
--  cannot both succeed.
-- =====================================================================
USE ecommerce_inventory;

DELIMITER $$

-- ---------------------------------------------------------------------
--  Place a single-product order, if there is enough stock.
--
--  CALL sp_place_order(5, 1, 12, 2, @new_order_id);
--  SELECT @new_order_id;
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_place_order $$
CREATE PROCEDURE sp_place_order(
    IN  p_customer_id  INT,
    IN  p_warehouse_id INT,
    IN  p_product_id   INT,
    IN  p_quantity     INT,
    OUT p_order_id     INT
)
BEGIN
    DECLARE v_on_hand INT DEFAULT NULL;
    DECLARE v_price   DECIMAL(10,2);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Quantity must be greater than zero';
    END IF;

    START TRANSACTION;

    SELECT quantity_on_hand INTO v_on_hand
    FROM inventory
    WHERE warehouse_id = p_warehouse_id AND product_id = p_product_id
    FOR UPDATE;

    IF v_on_hand IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product is not stocked in this warehouse';
    END IF;
    IF v_on_hand < p_quantity THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Not enough stock to fulfil this order';
    END IF;

    SELECT unit_price INTO v_price FROM products WHERE product_id = p_product_id AND is_active = 1;
    IF v_price IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Product is inactive or does not exist';
    END IF;

    INSERT INTO orders (customer_id, warehouse_id, order_date, status)
    VALUES (p_customer_id, p_warehouse_id, NOW(), 'paid');
    SET p_order_id = LAST_INSERT_ID();

    INSERT INTO order_items (order_id, product_id, quantity, unit_price, discount_pct)
    VALUES (p_order_id, p_product_id, p_quantity, v_price, 0);

    UPDATE inventory
    SET quantity_on_hand = quantity_on_hand - p_quantity
    WHERE warehouse_id = p_warehouse_id AND product_id = p_product_id;

    INSERT INTO stock_movements (product_id, warehouse_id, change_qty, reason, reference_id, moved_at)
    VALUES (p_product_id, p_warehouse_id, -p_quantity, 'sale', p_order_id, NOW());

    COMMIT;
END $$

-- ---------------------------------------------------------------------
--  Receive an open purchase order: add every line to stock.
--
--  CALL sp_receive_purchase_order(12);
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_receive_purchase_order $$
CREATE PROCEDURE sp_receive_purchase_order(IN p_po_id INT)
BEGIN
    DECLARE v_status    VARCHAR(20);
    DECLARE v_warehouse INT;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT status, warehouse_id INTO v_status, v_warehouse
    FROM purchase_orders
    WHERE po_id = p_po_id
    FOR UPDATE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Purchase order not found';
    END IF;
    IF v_status <> 'open' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only open purchase orders can be received';
    END IF;

    -- Create inventory rows for products this warehouse has never held.
    INSERT INTO inventory (warehouse_id, product_id, quantity_on_hand)
    SELECT v_warehouse, poi.product_id, 0
    FROM purchase_order_items poi
    WHERE poi.po_id = p_po_id
    ON DUPLICATE KEY UPDATE quantity_on_hand = quantity_on_hand;

    UPDATE inventory i
    JOIN purchase_order_items poi
      ON poi.product_id = i.product_id AND poi.po_id = p_po_id
    SET i.quantity_on_hand = i.quantity_on_hand + poi.quantity
    WHERE i.warehouse_id = v_warehouse;

    INSERT INTO stock_movements (product_id, warehouse_id, change_qty, reason, reference_id, moved_at)
    SELECT poi.product_id, v_warehouse, poi.quantity, 'purchase', p_po_id, NOW()
    FROM purchase_order_items poi
    WHERE poi.po_id = p_po_id;

    UPDATE purchase_orders
    SET status = 'received', received_at = CURDATE()
    WHERE po_id = p_po_id;

    COMMIT;
END $$

DELIMITER ;

-- =====================================================================
--  E-Commerce Inventory Database — schema
--  Target: MySQL 8.0+
--
--  Tracks a multi-warehouse retailer: what it sells, who supplies it,
--  how much is on hand where, what customers ordered, and every change
--  in stock (sales, purchases, returns, adjustments).
-- =====================================================================

DROP DATABASE IF EXISTS ecommerce_inventory;
CREATE DATABASE ecommerce_inventory CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE ecommerce_inventory;

-- ---------------------------------------------------------------------
--  Catalogue
-- ---------------------------------------------------------------------
CREATE TABLE categories (
    category_id   INT AUTO_INCREMENT PRIMARY KEY,
    name          VARCHAR(80)  NOT NULL UNIQUE,
    description   VARCHAR(255)
);

CREATE TABLE suppliers (
    supplier_id     INT AUTO_INCREMENT PRIMARY KEY,
    name            VARCHAR(120) NOT NULL UNIQUE,
    contact_email   VARCHAR(160) NOT NULL,
    phone           VARCHAR(20),
    city            VARCHAR(80),
    lead_time_days  INT NOT NULL DEFAULT 7,   -- what the supplier promises
    CONSTRAINT chk_supplier_lead_time CHECK (lead_time_days > 0)
);

CREATE TABLE products (
    product_id     INT AUTO_INCREMENT PRIMARY KEY,
    sku            VARCHAR(20)   NOT NULL UNIQUE,
    name           VARCHAR(150)  NOT NULL,
    category_id    INT           NOT NULL,
    supplier_id    INT           NOT NULL,
    unit_cost      DECIMAL(10,2) NOT NULL,
    unit_price     DECIMAL(10,2) NOT NULL,
    reorder_level  INT           NOT NULL DEFAULT 10,
    is_active      TINYINT(1)    NOT NULL DEFAULT 1,
    created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_products_category FOREIGN KEY (category_id) REFERENCES categories (category_id),
    CONSTRAINT fk_products_supplier FOREIGN KEY (supplier_id) REFERENCES suppliers (supplier_id),
    CONSTRAINT chk_products_cost    CHECK (unit_cost >= 0),
    CONSTRAINT chk_products_price   CHECK (unit_price >= unit_cost),
    CONSTRAINT chk_products_reorder CHECK (reorder_level >= 0)
);

-- ---------------------------------------------------------------------
--  Stock
-- ---------------------------------------------------------------------
CREATE TABLE warehouses (
    warehouse_id  INT AUTO_INCREMENT PRIMARY KEY,
    code          VARCHAR(10)  NOT NULL UNIQUE,
    name          VARCHAR(100) NOT NULL,
    city          VARCHAR(80)  NOT NULL
);

-- Current quantity of each product in each warehouse.
CREATE TABLE inventory (
    warehouse_id      INT NOT NULL,
    product_id        INT NOT NULL,
    quantity_on_hand  INT NOT NULL DEFAULT 0,
    updated_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (warehouse_id, product_id),
    CONSTRAINT fk_inventory_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id),
    CONSTRAINT fk_inventory_product   FOREIGN KEY (product_id)   REFERENCES products (product_id),
    CONSTRAINT chk_inventory_qty      CHECK (quantity_on_hand >= 0)
);

-- ---------------------------------------------------------------------
--  Sales
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  INT AUTO_INCREMENT PRIMARY KEY,
    first_name   VARCHAR(60)  NOT NULL,
    last_name    VARCHAR(60)  NOT NULL,
    email        VARCHAR(160) NOT NULL UNIQUE,
    city         VARCHAR(80),
    province     VARCHAR(40),
    created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE orders (
    order_id      INT AUTO_INCREMENT PRIMARY KEY,
    customer_id   INT NOT NULL,
    warehouse_id  INT NOT NULL,          -- warehouse the order ships from
    order_date    DATETIME NOT NULL,
    status        ENUM('pending', 'paid', 'shipped', 'delivered', 'cancelled', 'returned') NOT NULL DEFAULT 'pending',
    CONSTRAINT fk_orders_customer  FOREIGN KEY (customer_id)  REFERENCES customers (customer_id),
    CONSTRAINT fk_orders_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id)
);

CREATE TABLE order_items (
    order_id      INT NOT NULL,
    product_id    INT NOT NULL,
    quantity      INT NOT NULL,
    unit_price    DECIMAL(10,2) NOT NULL,      -- price at the time of sale
    discount_pct  DECIMAL(5,2)  NOT NULL DEFAULT 0,
    PRIMARY KEY (order_id, product_id),
    CONSTRAINT fk_items_order   FOREIGN KEY (order_id)   REFERENCES orders (order_id) ON DELETE CASCADE,
    CONSTRAINT fk_items_product FOREIGN KEY (product_id) REFERENCES products (product_id),
    CONSTRAINT chk_items_qty      CHECK (quantity > 0),
    CONSTRAINT chk_items_discount CHECK (discount_pct BETWEEN 0 AND 100)
);

-- ---------------------------------------------------------------------
--  Purchasing
-- ---------------------------------------------------------------------
CREATE TABLE purchase_orders (
    po_id         INT AUTO_INCREMENT PRIMARY KEY,
    supplier_id   INT  NOT NULL,
    warehouse_id  INT  NOT NULL,         -- where the stock is delivered
    ordered_at    DATE NOT NULL,
    received_at   DATE,                  -- NULL until delivered
    status        ENUM('open', 'received', 'cancelled') NOT NULL DEFAULT 'open',
    CONSTRAINT fk_po_supplier  FOREIGN KEY (supplier_id)  REFERENCES suppliers (supplier_id),
    CONSTRAINT fk_po_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id),
    CONSTRAINT chk_po_dates    CHECK (received_at IS NULL OR received_at >= ordered_at)
);

CREATE TABLE purchase_order_items (
    po_id       INT NOT NULL,
    product_id  INT NOT NULL,
    quantity    INT NOT NULL,
    unit_cost   DECIMAL(10,2) NOT NULL,
    PRIMARY KEY (po_id, product_id),
    CONSTRAINT fk_poi_po      FOREIGN KEY (po_id)      REFERENCES purchase_orders (po_id) ON DELETE CASCADE,
    CONSTRAINT fk_poi_product FOREIGN KEY (product_id) REFERENCES products (product_id),
    CONSTRAINT chk_poi_qty    CHECK (quantity > 0)
);

-- ---------------------------------------------------------------------
--  Audit trail: every change to stock, so inventory can be explained
-- ---------------------------------------------------------------------
CREATE TABLE stock_movements (
    movement_id   BIGINT AUTO_INCREMENT PRIMARY KEY,
    product_id    INT NOT NULL,
    warehouse_id  INT NOT NULL,
    change_qty    INT NOT NULL,           -- negative = stock out, positive = stock in
    reason        ENUM('sale', 'purchase', 'return', 'adjustment') NOT NULL,
    reference_id  INT,                    -- order_id or po_id, depending on reason
    moved_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_moves_product   FOREIGN KEY (product_id)   REFERENCES products (product_id),
    CONSTRAINT fk_moves_warehouse FOREIGN KEY (warehouse_id) REFERENCES warehouses (warehouse_id),
    CONSTRAINT chk_moves_nonzero  CHECK (change_qty <> 0)
);

-- ---------------------------------------------------------------------
--  Indexes for the reporting queries
-- ---------------------------------------------------------------------
CREATE INDEX idx_orders_date_status   ON orders (order_date, status);
CREATE INDEX idx_orders_customer      ON orders (customer_id);
CREATE INDEX idx_items_product        ON order_items (product_id);
CREATE INDEX idx_products_category    ON products (category_id);
CREATE INDEX idx_moves_product_date   ON stock_movements (product_id, moved_at);
CREATE INDEX idx_po_supplier_status   ON purchase_orders (supplier_id, status);

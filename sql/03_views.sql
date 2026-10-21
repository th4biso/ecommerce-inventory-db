-- =====================================================================
--  Views: reusable building blocks for the reports in 05_reports.sql
-- =====================================================================
USE ecommerce_inventory;

-- One row per order line with its net revenue, cost and margin.
-- Only orders that count as a sale (not pending, cancelled or returned).
CREATE OR REPLACE VIEW v_sales_lines AS
SELECT
    o.order_id,
    o.order_date,
    o.customer_id,
    o.warehouse_id,
    oi.product_id,
    p.category_id,
    oi.quantity,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100), 2) AS net_revenue,
    ROUND(oi.quantity * p.unit_cost, 2)                                  AS cost_of_goods,
    ROUND(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100)
          - oi.quantity * p.unit_cost, 2)                                AS gross_profit
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
JOIN products p     ON p.product_id = oi.product_id
WHERE o.status IN ('paid', 'shipped', 'delivered');

-- Stock per product across all warehouses, with its value at cost.
CREATE OR REPLACE VIEW v_product_stock AS
SELECT
    p.product_id,
    p.sku,
    p.name,
    p.category_id,
    p.reorder_level,
    COALESCE(SUM(i.quantity_on_hand), 0)               AS total_on_hand,
    ROUND(COALESCE(SUM(i.quantity_on_hand), 0) * p.unit_cost, 2) AS stock_value_at_cost
FROM products p
LEFT JOIN inventory i ON i.product_id = p.product_id
WHERE p.is_active = 1
GROUP BY p.product_id, p.sku, p.name, p.category_id, p.reorder_level, p.unit_cost;

-- Order header totals.
CREATE OR REPLACE VIEW v_order_totals AS
SELECT
    o.order_id,
    o.customer_id,
    o.order_date,
    o.status,
    COUNT(*)                                                                 AS line_count,
    SUM(oi.quantity)                                                         AS units,
    ROUND(SUM(oi.quantity * oi.unit_price * (1 - oi.discount_pct / 100)), 2) AS order_total
FROM orders o
JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY o.order_id, o.customer_id, o.order_date, o.status;

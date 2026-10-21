-- =====================================================================
--  Operational and performance reports
--
--  Each query answers one business question. Run them one at a time.
--  Reports that depend on "today" use an as-of date (the last day of the
--  sample data) so the results are reproducible; change it in `params`.
-- =====================================================================
USE ecommerce_inventory;


-- ---------------------------------------------------------------------
-- 1. How is revenue trending month to month?
--    Revenue, orders, average order value, margin, year-to-date running
--    total and month-on-month growth.
-- ---------------------------------------------------------------------
WITH monthly AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m') AS month,
        COUNT(DISTINCT order_id)         AS orders,
        SUM(net_revenue)                 AS revenue,
        SUM(gross_profit)                AS gross_profit
    FROM v_sales_lines
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
)
SELECT
    month,
    orders,
    ROUND(revenue, 2)                                   AS revenue,
    ROUND(revenue / orders, 2)                          AS avg_order_value,
    ROUND(100.0 * gross_profit / revenue, 1)            AS gross_margin_pct,
    ROUND(SUM(revenue) OVER (ORDER BY month), 2)        AS revenue_ytd,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (ORDER BY month))
          / LAG(revenue) OVER (ORDER BY month), 1)      AS mom_growth_pct
FROM monthly
ORDER BY month;


-- ---------------------------------------------------------------------
-- 2. What are the top three products in each category?
-- ---------------------------------------------------------------------
WITH product_sales AS (
    SELECT
        c.name           AS category,
        p.sku,
        p.name           AS product,
        SUM(s.quantity)  AS units_sold,
        SUM(s.net_revenue) AS revenue
    FROM v_sales_lines s
    JOIN products p   ON p.product_id = s.product_id
    JOIN categories c ON c.category_id = p.category_id
    GROUP BY c.name, p.sku, p.name
),
ranked AS (
    SELECT
        ps.*,
        RANK() OVER (PARTITION BY category ORDER BY revenue DESC)              AS rank_in_category,
        ROUND(100.0 * revenue / SUM(revenue) OVER (PARTITION BY category), 1) AS share_of_category_pct
    FROM product_sales ps
)
SELECT category, rank_in_category, sku, product, units_sold, ROUND(revenue, 2) AS revenue, share_of_category_pct
FROM ranked
WHERE rank_in_category <= 3
ORDER BY category, rank_in_category;


-- ---------------------------------------------------------------------
-- 3. What needs reordering, and how many days of stock are left?
--    Days of cover = stock on hand / average daily sales (last 30 days).
-- ---------------------------------------------------------------------
WITH params AS (SELECT '2026-09-30' AS as_of),
recent_sales AS (
    SELECT s.product_id, SUM(s.quantity) / 30.0 AS avg_daily_units
    FROM v_sales_lines s
    CROSS JOIN params
    WHERE s.order_date > DATE_SUB(params.as_of, INTERVAL 30 DAY)
    GROUP BY s.product_id
),
open_po AS (
    SELECT poi.product_id, SUM(poi.quantity) AS on_order
    FROM purchase_orders po
    JOIN purchase_order_items poi ON poi.po_id = po.po_id
    WHERE po.status = 'open'
    GROUP BY poi.product_id
),
stock_status AS (
    SELECT
        ps.sku,
        ps.name,
        ps.total_on_hand,
        ps.reorder_level,
        COALESCE(op.on_order, 0)                     AS on_order,
        ROUND(COALESCE(rs.avg_daily_units, 0), 2)    AS avg_daily_units,
        CASE WHEN COALESCE(rs.avg_daily_units, 0) = 0 THEN NULL
             ELSE ROUND(ps.total_on_hand / rs.avg_daily_units, 1) END AS days_of_cover,
        CASE
            WHEN ps.total_on_hand = 0                                         THEN 'OUT OF STOCK'
            WHEN ps.total_on_hand + COALESCE(op.on_order, 0) < ps.reorder_level THEN 'REORDER NOW'
            WHEN ps.total_on_hand < ps.reorder_level                          THEN 'LOW - stock on order'
            ELSE 'OK'
        END AS status
    FROM v_product_stock ps
    LEFT JOIN recent_sales rs ON rs.product_id = ps.product_id
    LEFT JOIN open_po op      ON op.product_id = ps.product_id
)
SELECT *
FROM stock_status
WHERE status <> 'OK' OR days_of_cover < 14
ORDER BY days_of_cover IS NULL, days_of_cover;


-- ---------------------------------------------------------------------
-- 4. What is the stock in each warehouse worth?
-- ---------------------------------------------------------------------
SELECT
    w.code                                                          AS warehouse,
    w.city,
    SUM(i.quantity_on_hand)                                         AS units_on_hand,
    SUM(CASE WHEN i.quantity_on_hand = 0 THEN 1 ELSE 0 END)         AS products_out_of_stock,
    ROUND(SUM(i.quantity_on_hand * p.unit_cost), 2)                 AS value_at_cost,
    ROUND(SUM(i.quantity_on_hand * p.unit_price), 2)                AS value_at_retail,
    ROUND(SUM(i.quantity_on_hand * (p.unit_price - p.unit_cost)), 2) AS potential_gross_profit
FROM inventory i
JOIN warehouses w ON w.warehouse_id = i.warehouse_id
JOIN products p   ON p.product_id = i.product_id
GROUP BY w.warehouse_id, w.code, w.city
ORDER BY value_at_cost DESC;


-- ---------------------------------------------------------------------
-- 5. ABC analysis: which products earn most of the revenue?
--    A = the products making up the first 80% of revenue, B = the next
--    15%, C = the last 5%. Tells you where stock-outs hurt most.
-- ---------------------------------------------------------------------
WITH product_revenue AS (
    SELECT p.sku, p.name, SUM(s.net_revenue) AS revenue
    FROM v_sales_lines s
    JOIN products p ON p.product_id = s.product_id
    GROUP BY p.sku, p.name
),
cumulative AS (
    SELECT
        pr.*,
        SUM(revenue) OVER (ORDER BY revenue DESC, sku ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            / SUM(revenue) OVER () AS cumulative_share
    FROM product_revenue pr
)
SELECT
    sku,
    name,
    ROUND(revenue, 2)                AS revenue,
    ROUND(100 * cumulative_share, 1) AS cumulative_pct,
    CASE WHEN cumulative_share <= 0.80 THEN 'A'
         WHEN cumulative_share <= 0.95 THEN 'B'
         ELSE 'C' END                AS abc_class
FROM cumulative
ORDER BY revenue DESC;


-- ---------------------------------------------------------------------
-- 6. Dead stock: what is sitting on the shelf and not selling?
--    In stock, but no sale in the last 60 days.
-- ---------------------------------------------------------------------
WITH params AS (SELECT '2026-09-30' AS as_of),
last_sale AS (
    SELECT product_id, MAX(order_date) AS last_sold
    FROM v_sales_lines
    GROUP BY product_id
)
SELECT
    ps.sku,
    ps.name,
    ps.total_on_hand,
    ps.stock_value_at_cost,
    DATE(ls.last_sold)                      AS last_sold,
    DATEDIFF(params.as_of, ls.last_sold)    AS days_since_last_sale
FROM v_product_stock ps
CROSS JOIN params
LEFT JOIN last_sale ls ON ls.product_id = ps.product_id
WHERE ps.total_on_hand > 0
  AND (ls.last_sold IS NULL OR ls.last_sold < DATE_SUB(params.as_of, INTERVAL 60 DAY))
ORDER BY ps.stock_value_at_cost DESC;


-- ---------------------------------------------------------------------
-- 7. Customer segmentation (RFM: recency, frequency, monetary value)
--    Each customer is scored 1-4 on each measure against the others.
-- ---------------------------------------------------------------------
WITH params AS (SELECT '2026-09-30' AS as_of),
customer_stats AS (
    SELECT customer_id, MAX(order_date) AS last_order, COUNT(*) AS orders, SUM(order_total) AS spend
    FROM v_order_totals
    WHERE status IN ('paid', 'shipped', 'delivered')
    GROUP BY customer_id
),
scored AS (
    SELECT
        cs.*,
        DATEDIFF(params.as_of, cs.last_order)  AS recency_days,
        NTILE(4) OVER (ORDER BY cs.last_order) AS r_score,
        NTILE(4) OVER (ORDER BY cs.orders)     AS f_score,
        NTILE(4) OVER (ORDER BY cs.spend)      AS m_score
    FROM customer_stats cs
    CROSS JOIN params
)
SELECT
    CONCAT(c.first_name, ' ', c.last_name) AS customer,
    c.city,
    s.orders,
    ROUND(s.spend, 2) AS total_spend,
    s.recency_days,
    s.r_score, s.f_score, s.m_score,
    CASE
        WHEN s.r_score >= 3 AND s.f_score >= 3 AND s.m_score >= 3 THEN 'Champion'
        WHEN s.r_score >= 3 AND s.f_score >= 2                    THEN 'Loyal'
        WHEN s.r_score = 2  AND s.f_score >= 3                    THEN 'Needs attention'
        WHEN s.r_score <= 1 AND s.f_score >= 3                    THEN 'At risk'
        WHEN s.r_score <= 1                                       THEN 'Lapsed'
        ELSE 'Developing'
    END AS segment
FROM scored s
JOIN customers c ON c.customer_id = s.customer_id
ORDER BY s.spend DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- 8. Are suppliers delivering on time?
-- ---------------------------------------------------------------------
SELECT
    s.name                                                       AS supplier,
    s.lead_time_days                                             AS promised_days,
    COUNT(*)                                                     AS deliveries,
    ROUND(AVG(DATEDIFF(po.received_at, po.ordered_at)), 1)       AS avg_actual_days,
    SUM(CASE WHEN DATEDIFF(po.received_at, po.ordered_at) > s.lead_time_days THEN 1 ELSE 0 END) AS late_deliveries,
    ROUND(100.0 * SUM(CASE WHEN DATEDIFF(po.received_at, po.ordered_at) > s.lead_time_days THEN 1 ELSE 0 END)
          / COUNT(*), 1)                                         AS late_pct
FROM purchase_orders po
JOIN suppliers s ON s.supplier_id = po.supplier_id
WHERE po.status = 'received'
GROUP BY s.supplier_id, s.name, s.lead_time_days
ORDER BY late_pct DESC;


-- ---------------------------------------------------------------------
-- 9. Which categories make the money (not just the revenue)?
-- ---------------------------------------------------------------------
SELECT
    c.name                                                       AS category,
    SUM(s.quantity)                                              AS units_sold,
    ROUND(SUM(s.net_revenue), 2)                                 AS revenue,
    ROUND(SUM(s.gross_profit), 2)                                AS gross_profit,
    ROUND(100.0 * SUM(s.gross_profit) / SUM(s.net_revenue), 1)   AS gross_margin_pct,
    ROUND(100.0 * SUM(s.net_revenue) / SUM(SUM(s.net_revenue)) OVER (), 1) AS share_of_revenue_pct
FROM v_sales_lines s
JOIN categories c ON c.category_id = s.category_id
GROUP BY c.category_id, c.name
ORDER BY gross_profit DESC;


-- ---------------------------------------------------------------------
-- 10. Which products are bought together? (input for bundles and
--     "customers also bought")
-- ---------------------------------------------------------------------
SELECT
    pa.name  AS product_a,
    pb.name  AS product_b,
    COUNT(*) AS orders_together
FROM v_sales_lines a
JOIN v_sales_lines b ON b.order_id = a.order_id AND a.product_id < b.product_id
JOIN products pa     ON pa.product_id = a.product_id
JOIN products pb     ON pb.product_id = b.product_id
GROUP BY pa.name, pb.name
HAVING COUNT(*) >= 3
ORDER BY orders_together DESC, product_a
LIMIT 10;


-- ---------------------------------------------------------------------
-- 11. Cancellation and return rates by month
-- ---------------------------------------------------------------------
SELECT
    DATE_FORMAT(order_date, '%Y-%m')                                                  AS month,
    COUNT(*)                                                                          AS orders,
    ROUND(100.0 * SUM(CASE WHEN status = 'cancelled' THEN 1 ELSE 0 END) / COUNT(*), 1) AS cancelled_pct,
    ROUND(100.0 * SUM(CASE WHEN status = 'returned'  THEN 1 ELSE 0 END) / COUNT(*), 1) AS returned_pct
FROM orders
GROUP BY DATE_FORMAT(order_date, '%Y-%m')
ORDER BY month;


-- ---------------------------------------------------------------------
-- 12. Data integrity check: does stock on hand equal the sum of every
--     recorded movement? Should return no rows.
-- ---------------------------------------------------------------------
SELECT
    i.warehouse_id,
    i.product_id,
    i.quantity_on_hand,
    COALESCE(m.net_movement, 0) AS net_movement
FROM inventory i
LEFT JOIN (
    SELECT warehouse_id, product_id, SUM(change_qty) AS net_movement
    FROM stock_movements
    GROUP BY warehouse_id, product_id
) m ON m.warehouse_id = i.warehouse_id AND m.product_id = i.product_id
WHERE i.quantity_on_hand <> COALESCE(m.net_movement, 0);

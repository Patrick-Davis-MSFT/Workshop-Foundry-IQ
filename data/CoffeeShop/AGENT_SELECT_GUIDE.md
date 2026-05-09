# CoffeeShop Azure SQL Query Guide For Agents

## Connection Inputs

When querying this database, collect these values first:
- Azure SQL server endpoint (example: sqlpcddemo.database.windows.net)
- Azure SQL username
- Azure SQL password
- Database name (default: coffee_shop)

## Core Tables

- menu_items (item_id PK)
- payment_methods (payment_method_id PK)
- stores (store_id PK)
- users (user_id PK)
- vouchers (voucher_id PK)
- transactions (transaction_id PK)
- transaction_items (composite PK)

## Relationships

- transactions.store_id -> stores.store_id
- transactions.payment_method_id -> payment_methods.payment_method_id
- transactions.voucher_id -> vouchers.voucher_id
- transactions.user_id -> users.user_id
- transaction_items.transaction_id -> transactions.transaction_id
- transaction_items.item_id -> menu_items.item_id

## Recommended Query Pattern

Use transactions as the fact table, then join dimensions and line items:

1. Start with transactions filtered by date range.
2. Join transaction_items for product-level details.
3. Join menu_items for item metadata.
4. Left join vouchers and users because they can be null.
5. Join stores and payment_methods for channel/location analysis.

## Example: Full Transaction View

```sql
SELECT TOP (200)
  t.transaction_id,
  t.created_at,
  s.store_name,
  pm.method_name AS payment_method,
  u.user_id,
  v.voucher_code,
  ti.item_id,
  mi.item_name,
  ti.quantity,
  ti.unit_price,
  ti.subtotal,
  t.original_amount,
  t.discount_applied,
  t.final_amount
FROM dbo.transactions t
JOIN dbo.stores s ON s.store_id = t.store_id
JOIN dbo.payment_methods pm ON pm.payment_method_id = t.payment_method_id
LEFT JOIN dbo.users u ON u.user_id = t.user_id
LEFT JOIN dbo.vouchers v ON v.voucher_id = t.voucher_id
JOIN dbo.transaction_items ti ON ti.transaction_id = t.transaction_id
JOIN dbo.menu_items mi ON mi.item_id = ti.item_id
ORDER BY t.created_at DESC;
```

## Example: Monthly Revenue

```sql
SELECT
  CONVERT(char(7), t.created_at, 126) AS year_month,
  COUNT(DISTINCT t.transaction_id) AS transactions,
  ROUND(SUM(t.final_amount), 2) AS revenue,
  ROUND(SUM(t.discount_applied), 2) AS discount_total
FROM dbo.transactions t
GROUP BY CONVERT(char(7), t.created_at, 126)
ORDER BY year_month;
```

## Example: Top Items By Revenue

```sql
SELECT TOP (20)
  mi.item_name,
  SUM(ti.quantity) AS units_sold,
  ROUND(SUM(ti.subtotal), 2) AS gross_sales
FROM dbo.transaction_items ti
JOIN dbo.menu_items mi ON mi.item_id = ti.item_id
GROUP BY mi.item_name
ORDER BY gross_sales DESC;
```

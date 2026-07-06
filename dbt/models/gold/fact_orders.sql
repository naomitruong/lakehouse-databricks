{{ config(materialized='table') }}

select
    o.order_id,
    o.customer_id,
    c.customer_name,
    o.amount,
    cast(o.order_date as date)  as order_date,
    o.last_operation,
    o._ingested_at
from {{ ref('orders_silver') }} o
left join {{ ref('customers_silver') }} c
    on o.customer_id = c.customer_id

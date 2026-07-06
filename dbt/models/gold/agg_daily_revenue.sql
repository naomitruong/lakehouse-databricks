{{ config(materialized='table') }}

select
    cast(order_date as date)    as order_date_day,
    count(order_id)             as total_orders,
    sum(amount)                 as total_revenue,
    avg(amount)                 as avg_order_value
from {{ ref('orders_silver') }}
group by cast(order_date as date)

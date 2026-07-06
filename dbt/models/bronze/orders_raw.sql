select
    order_id,
    customer_id,
    amount,
    order_date,
    _cdc_deleted,
    _cdc_op,
    _cdc_ts_ms,
    _ingested_at

from {{ source('bronze_delta', 'orders') }}

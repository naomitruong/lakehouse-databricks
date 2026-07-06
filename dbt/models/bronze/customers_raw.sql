select
    customer_id,
    customer_name,
    join_date,
    _cdc_op,
    _cdc_ts_ms,
    _ingested_at
from {{ source('bronze_delta', 'customers') }}

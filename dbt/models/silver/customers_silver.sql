{{
    config(
        materialized='incremental',
        unique_key='customer_id',
        incremental_strategy='merge'
    )
}}

with source as (

    select * from {{ ref('customers_raw') }}

    {% if is_incremental() %}
    where _ingested_at > (select max(_ingested_at) from {{ this }})
    {% endif %}

),

deduped as (

    select
        customer_id,
        customer_name,
        join_date,
        _cdc_op      as last_operation,
        _cdc_ts_ms,
        _ingested_at,
        row_number() over (
            partition by customer_id
            order by _cdc_ts_ms desc
        ) as _rn

    from source

)

select
    customer_id,
    customer_name,
    join_date,
    last_operation,
    _cdc_ts_ms,
    _ingested_at
from deduped
where _rn = 1
  and last_operation != 'd'

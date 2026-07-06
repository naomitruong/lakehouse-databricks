select order_id, amount
from {{ ref('orders_silver') }}
where amount < 0

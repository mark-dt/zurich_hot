hostname
uptime
curl "http://$(kubectl -n workshop get svc payment-service -o jsonpath='{.spec.clusterIP}'):3002/pay?orderId=MY-ORDER-42&amount=99.99"
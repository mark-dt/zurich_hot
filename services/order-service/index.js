const express = require("express");
const http = require("http");

const app = express();
const PORT = process.env.PORT || 3001;
const PAYMENT_SERVICE = process.env.PAYMENT_SERVICE_URL || "http://payment-service.workshop.svc.cluster.local:3002";
const INVENTORY_SERVICE = process.env.INVENTORY_SERVICE_URL || "http://inventory-service.workshop.svc.cluster.local:3003";

function fetch(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (res) => {
      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve({ status: res.statusCode, data }));
    }).on("error", reject);
  });
}

app.get("/health", (req, res) => {
  res.json({ service: "order-service", status: "ok" });
});

app.get("/order", async (req, res) => {
  const start = Date.now();
  const orderId = `ORD-${Date.now()}`;

  try {
    const [paymentResult, inventoryResult] = await Promise.all([
      fetch(`${PAYMENT_SERVICE}/pay?orderId=${orderId}&amount=49.99`),
      fetch(`${INVENTORY_SERVICE}/check?item=WIDGET-1&qty=1`),
    ]);

    const duration = Date.now() - start;
    const paymentOk = paymentResult.status === 200;
    const inventoryOk = inventoryResult.status === 200;

    console.log(JSON.stringify({ service: "order-service", path: "/order", orderId, paymentStatus: paymentResult.status, inventoryStatus: inventoryResult.status, duration }));

    if (paymentOk && inventoryOk) {
      res.json({ orderId, status: "confirmed", payment: JSON.parse(paymentResult.data), inventory: JSON.parse(inventoryResult.data) });
    } else {
      res.status(500).json({ orderId, status: "failed", paymentOk, inventoryOk });
    }
  } catch (err) {
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "order-service", path: "/order", orderId, error: err.message, duration }));
    res.status(502).json({ orderId, status: "error", error: err.message });
  }
});

app.listen(PORT, () => console.log(`order-service listening on :${PORT}`));

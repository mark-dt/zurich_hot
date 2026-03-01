const express = require("express");
const http = require("http");

const app = express();
const PORT = process.env.PORT || 3000;
const ORDER_SERVICE = process.env.ORDER_SERVICE_URL || "http://order-service.workshop.svc.cluster.local:3001";

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
  res.json({ service: "frontend", status: "ok" });
});

app.get("/order", async (req, res) => {
  const start = Date.now();
  try {
    const result = await fetch(`${ORDER_SERVICE}/order`);
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "frontend", method: "GET", path: "/order", upstream_status: result.status, duration }));
    res.status(result.status).json(JSON.parse(result.data));
  } catch (err) {
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "frontend", method: "GET", path: "/order", error: err.message, duration }));
    res.status(502).json({ error: "order-service unavailable" });
  }
});

app.listen(PORT, () => console.log(`frontend listening on :${PORT}`));

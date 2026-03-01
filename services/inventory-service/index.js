const express = require("express");

const app = express();
const PORT = process.env.PORT || 3003;

app.get("/health", (req, res) => {
  res.json({ service: "inventory-service", status: "ok" });
});

app.get("/check", (req, res) => {
  const start = Date.now();
  const { item, qty } = req.query;

  // Simulate a quick DB lookup
  const delay = 20 + Math.random() * 80; // 20-100ms
  setTimeout(() => {
    const inStock = Math.random() > 0.05; // 95% in stock
    const duration = Date.now() - start;
    console.log(JSON.stringify({ service: "inventory-service", path: "/check", item, qty, inStock, duration }));
    res.json({ item, qty: parseInt(qty) || 1, inStock, warehouse: "EU-WEST-1" });
  }, delay);
});

app.listen(PORT, () => console.log(`inventory-service listening on :${PORT}`));

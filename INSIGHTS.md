# Insight Memos: What the Data Says and What To Do About It

Three short memos written the way an analyst would hand them to a marketing or product lead.
All figures come from the queries in `sql/` and are reproducible. The data is synthetic.

---

## Memo 1: When should we contact customers who stop buying?

**Question:** How long do customers normally wait between orders, and at what point does silence mean we are losing them?

**Method:** `LAG()` over each customer's completed orders gave the days between consecutive purchases
(788 repeat purchases). Percentiles of that distribution define the lifecycle stages
(`05_purchase_gap_churn.sql`).

**Findings**
- Half of all repeat orders happen within **39 days** of the previous one, 75% within **72 days**, 90% within **115 days**.
- The first repeat is the slowest: **64 days** from order 1 to 2, versus about **48 days** later on. Customers who pass the second order reorder faster.
- Using those thresholds, **87.5% of buyers are already churned** (inactive over 115 days), **8.3% are At Risk** and only **4.2% are Active**.
- The 36 At Risk customers hold **$95K of lifetime revenue (16% of the total)**. This is the group still worth saving.
- Churn varies by acquisition channel: **Paid Search 94%** churned vs **Referral 81%**.
- In the cohort matrix, on average about **28%** of a cohort buys again in month 1, falling to roughly **12% by month 6**. The steepest loss is early.

**Recommendation: trigger campaigns on these day marks**

| Day since last order | Action | Why |
|---|---|---|
| 39 | Friendly reminder email | Half of repeat orders have happened; catch the rest before the habit fades |
| 72 | Win-back offer (discount code) | 75% of repeat orders are done; silence beyond this is unusual |
| 115 | Last-chance message + "why did you leave?" survey | Past the point where 90% of customers have returned |

Start by emailing the At Risk list (query Q8 returns the top accounts by lifetime value).
Because the first repeat is the slowest, an **order-1 follow-up around day 30** is the single cheapest retention lever.

---

## Memo 2: Where does the funnel leak, and should we ship the new checkout?

**Question:** Where do shoppers drop out, and did the new one-page checkout (variant B) improve purchases?

**Method:** Session event log pivoted to one row per session, funnel rates by device and channel, then a
two-proportion z-test with a 95% confidence interval and a power check, all in SQL
(`06_funnel_seed.sql`, `07_funnel_ab_analysis.sql`).

**Funnel findings (30,000 sessions)**
- Visit → product view 52.9% → add to cart 27.5% → checkout 56.4% → purchase 60.8%. **Overall conversion: 5.0%.**
- The biggest leak is **product view → add to cart (72.5% leave)**, ahead of the checkout stage.
- **Mobile converts at 3.26% vs desktop at 7.67%**, and mobile is 55% of traffic. Closing even part of that gap is the largest opportunity.

**A/B test result (checkout → purchase)**
- Variant A **55.93%** vs variant B **65.59%**: **+9.66 percentage points (+17.3% relative)**.
- z = **4.91**, 95% CI for the lift **[+5.82, +13.50] pp**: statistically significant.
- Power check: about 1,220 checkouts per arm vs ~410 needed, so the test was **adequately powered**.
- Desktop lift +12.25 pp, mobile +8.52 pp. **Tablet +1.74 pp is not conclusive** (only ~125 checkouts per arm), so don't claim a tablet effect.
- Impact: roughly **966 extra orders per 10,000 checkout starts**, about **$475K** at the current $491 average order value.

**Recommendation:** Ship variant B to all devices. Then test product-page changes aimed at the view → cart step (for example sticky add-to-cart on mobile), since that is where the most sessions are lost.
Keep monitoring tablet separately.

---

## Memo 3: Which marketing channels pay for themselves?

**Question:** Does each channel's customer earn back what it cost to acquire them?

**Method:** Cohort of customers who signed up Jan-Oct 2024 (so each has a full 12 months of history). LTV is measured on **gross profit**, not revenue.
CAC = channel spend / new customers. Payback uses cumulative gross profit by month since signup (`08_marketing_seed.sql`, `09_clv_cac_analysis.sql`).

| Channel | CAC | 12-month LTV | LTV:CAC | Payback | Share of spend | Share of profit |
|---|---|---|---|---|---|---|
| Organic | $29 | $705 | 24.0x | month 1 | 4.6% | 28.3% |
| Email | $45 | $425 | 9.4x | month 1 | 8.3% | 20.1% |
| Referral | $98 | $490 | 5.0x | month 1 | 16.2% | 21.0% |
| Social | $153 | $365 | 2.4x | month 2 | 32.3% | 19.9% |
| Paid Search | $245 | $262 | 1.07x | month 9 | **38.6%** | **10.7%** |

**Findings**
- **Paid Search takes the largest share of budget (38.6%) but produces only 10.7% of gross profit**, barely above break-even (LTV:CAC 1.07) and a 9-month payback.
- Referral and Email deliver 5-9 dollars of gross profit per dollar spent, on only 25% of budget.
- Paid Search customers also reorder least (1.4 orders in 12 months vs 3.6 for Organic).

**Recommendation:** Cap Paid Search, and move part of that budget into the Referral and Email programs.
*Illustration, assuming returns stay constant (they won't, so treat it as an upper bound):* moving about $3.8K (25% of Paid Search spend) to Referral would add roughly $15K of gross profit.
Organic has the best ratio, but it is not a budget dial, so the practical move is to invest in the content that drives it.
Before cutting Paid Search entirely, check whether it feeds assisted conversions that last-touch data hides.

---

### Caveats (worth stating in an interview)
- The dataset is synthetic. Spend figures and the A/B effect were designed into the data, and the SQL's job is to recover them correctly.
- Churn is defined from this dataset's own repurchase rhythm; a business with different buying cycles needs its own thresholds.
- LTV here is 12-month realized gross profit, not a forecast of lifetime value.

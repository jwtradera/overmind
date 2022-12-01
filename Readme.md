Paper Pays Diamond:

- Owner sets number of depositors, n, amount per depositor, X, and a withdrawal vector [w_1,…, w_n], where w_i is the fraction of total deposits which the ith depositor can withdraw, in withdrawal order, i.e. first to withdraw gets w_1 fraction of the total, second w_2, and so on. w_1 ≤ w_2 … ≤ w_n, and the vector sums to 1.
- Anyone can deposit X into the contract
- As soon as there are n depositors, the game begins. Withdrawals are enabled.
- Owner sets an expiry timestamp T. If there are fewer than n depositors by T, the game is cancelled. All depositors can withdraw 100% of their deposit.
- You are also expected to build out any tests needed to ensure the above specifications are covered.
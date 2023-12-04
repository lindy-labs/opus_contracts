---
description: Autonomous interest rate governor
---

# Controller Module

The Controller module autonomously adjusts the value of a global interest rate multiplier for troves based on the deviation of the spot market price from the peg price. Its goal is to minimize the peg error by adjusting the interest rate multiplier to influence the behaviour of trove owners.

The core idea of the controller is:

* If the market price of `yin` goes above peg, then the multiplier should drop below 1 to encourage users to forge new `yin`. By decreasing interest rates across the board, it makes it cheaper for users to take on debt, thereby applying downward pressure on the market price of `yin` by increasing the supply of `yin`.
* If the market price of `yin` goes below peg, then the multiplier should increase above 1 to discourage users from forging new `yin` and encourage trove owners to repay their existing debt. By increasing interest rates across the board, it makes it more expensive for users to take on debt, thereby applying upward pressure on the market price of `yin` by decreasing the supply of `yin`.

## Specification

The controller is mostly a standard PI (Proportional-Integral) controller, except the error is first fed through a nonlinear function. This is done to better control how the controller reacts to errors of various magnitudes.&#x20;

In concrete terms, thanks to this nonlinearity, the controller may not react very aggressively to an error of 0.01, but react 'disproportionately' more aggressively to an error of 0.015.&#x20;

This is desirable because small deviations in the synthetic's price can happen for a number of benign reasons and should not necessarily be 'punished' by the controller, but larger deviations can be a sign of a true mismatch between supply and demand and must therefore be harshly corrected by the controller before they spiral out of control.&#x20;

The Controller acts according to this formula:

$$
y[k] = 1 + k_p \frac{ u[k]^{\alpha_{kp}}}{\sqrt{1 + u[k]^{\beta_{kp}}}} + y_i[k-1] + k_i \frac{u[k-1]|^{\alpha_{ki}}}{\sqrt{1 + u[k-1]^{\beta_{ki}}}} \cdot \Delta t
$$

Where:

* $$u[k]$$ is the error at time step $$k$$
* $$y[k]$$ is the multiplier at time step $$k$$
* the term multiplied by $$k_p$$ is the proportional term
* $$y_i[k-1]$$ is the integral term at time step $$k-1$$
* the term multiplied by $$k_i$$ is the integral term
* $$\Delta t$$ is the number of time steps that have passed since the last update to the controller

There are four parameters that can be tuned:

1. $$k_p$$: the gain (i.e., multiplier/scalar) that is applied to the proportional term
2. $$k_i$$: the gain that is applied to the integral term
3. $$\alpha_{k}$$ & $$\beta_{k}$$: control the 'severity' of the controller's reaction to price deviations from the peg in a nonlinear way

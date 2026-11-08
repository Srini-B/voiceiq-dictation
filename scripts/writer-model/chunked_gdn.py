"""A chunked gated-delta rule for training Qwen3.5 with MLX.

mlx-lm 0.32 trains Qwen3.5's linear-attention layers with a per-token Python
loop (`gated_delta_ops`), because its Metal kernel has no gradient. That loop
keeps one [B, H, Dv, Dk] state per token for the backward pass: about 1.7 GB
per 256 tokens on Qwen3.5-2B and about 45 tokens/s on an M2, so a 1,500-token
example does not fit in 16 GB. This is the chunked form of the same recurrence
(the algorithm of transformers' `torch_chunk_gated_delta_rule`), written in
MLX ops so autograd handles the backward pass: matmuls inside each 64-token
chunk and one state per chunk.

Inside a chunk the WY correction (I + M)^-1, with M strictly lower triangular,
is built by blocked inversion that doubles the block size (1, 2, ..., 64): the
lower-left block of [[A, 0], [C, D]]^-1 is -D^-1 C A^-1. That replaces the
row-by-row loop with six levels of small matmuls. (The nilpotent series
(I + N)(I + N^2)... is exact on paper, but with real, nearly parallel keys the
powers of N reach ~1e17 and float32 cancellation leaves an inverse that is off by
~1e9 and turns NaN.)

`patch()` swaps it into mlx_lm.models.qwen3_5 for training only (the
use_kernel=False, unmasked path); inference keeps the Metal kernel.
"""
import mlx.core as mx
import mlx.nn as nn

from mlx_lm.models import gated_delta as gd

CHUNK = 64


def chunked_gated_delta(q, k, v, log_g, beta, state=None, chunk=CHUNK):
    """q, k: [B, T, Hk, Dk] (q already scaled); v: [B, T, Hv, Dv];
    log_g, beta: [B, T, Hv]; state: [B, Hv, Dv, Dk].
    Returns y [B, T, Hv, Dv] and the final state [B, Hv, Dv, Dk]."""
    B, T, Hk, Dk = q.shape
    Hv, Dv = v.shape[-2:]
    dtype = q.dtype
    if Hv // Hk > 1:
        q = mx.repeat(q, Hv // Hk, -2)
        k = mx.repeat(k, Hv // Hk, -2)
    pad = (chunk - T % chunk) % chunk
    f32 = mx.float32

    def prep(x):  # [B, T, H, D] -> [B, H, N, C, D]
        x = x.astype(f32).transpose(0, 2, 1, 3)
        if pad:
            x = mx.pad(x, [(0, 0), (0, 0), (0, pad), (0, 0)])
        return x.reshape(B, Hv, -1, chunk, x.shape[-1])

    q, k, v = prep(q), prep(k), prep(v)
    beta = prep(beta[..., None])[..., 0]          # [B, H, N, C]
    g = prep(log_g[..., None])[..., 0]            # padded steps have log decay 0
    n = q.shape[2]

    k_beta = k * beta[..., None]
    v_beta = v * beta[..., None]
    g = mx.cumsum(g, axis=-1)
    lower = mx.tril(mx.ones((chunk, chunk), dtype=mx.bool_))
    strict = mx.tril(mx.ones((chunk, chunk), dtype=mx.bool_), k=-1)
    diff = g[..., :, None] - g[..., None, :]
    decay = mx.where(lower, mx.exp(mx.where(lower, diff, 0.0)), 0.0)  # [B, H, N, C, C]

    m = mx.where(strict, (k_beta @ k.swapaxes(-1, -2)) * decay, 0.0)  # [B, H, N, C, C]
    t_inv = unit_lower_inverse(m)
    u = t_inv @ v_beta                                  # [B, H, N, C, Dv]
    w = t_inv @ (k_beta * mx.exp(g)[..., None])         # [B, H, N, C, Dk]

    S = mx.zeros((B, Hv, Dk, Dv), dtype=f32) if state is None else state.astype(f32).swapaxes(-1, -2)
    ys = []
    for i in range(n):
        qi, ki, gi = q[:, :, i], k[:, :, i], g[:, :, i]
        attn = mx.where(lower, (qi @ ki.swapaxes(-1, -2)) * decay[:, :, i], 0.0)
        v_new = u[:, :, i] - w[:, :, i] @ S
        ys.append((qi * mx.exp(gi)[..., None]) @ S + attn @ v_new)
        g_last = gi[..., -1:]
        S = S * mx.exp(g_last)[..., None] + (ki * mx.exp(g_last - gi)[..., None]).swapaxes(-1, -2) @ v_new
    y = mx.stack(ys, axis=2).reshape(B, Hv, -1, Dv)[:, :, :T]
    return y.transpose(0, 2, 1, 3).astype(dtype), S.swapaxes(-1, -2)


def unit_lower_inverse(m):
    """(I + m)^-1 for strictly lower triangular m [..., C, C], C a power of two."""
    C = m.shape[-1]
    blocks = mx.ones(m.shape[:-2] + (C, 1, 1), dtype=m.dtype)  # inverses of the 1x1 diagonal blocks
    b = 1
    while b < C:
        n = C // (2 * b)
        pairs = blocks.reshape(m.shape[:-2] + (n, 2, b, b))
        a_inv, d_inv = pairs[..., 0, :, :], pairs[..., 1, :, :]
        # Lower-left b x b block of each 2b x 2b diagonal block of m.
        mr = m.reshape(m.shape[:-2] + (n, 2 * b, n, 2 * b))
        diag = (mr * mx.eye(n, dtype=m.dtype)[:, None, :, None]).sum(axis=-2)  # [..., n, 2b, 2b]
        off = -(d_inv @ diag[..., b:, :b] @ a_inv)
        top = mx.concatenate([a_inv, mx.zeros_like(a_inv)], axis=-1)
        blocks = mx.concatenate([top, mx.concatenate([off, d_inv], axis=-1)], axis=-2)
        b *= 2
    return blocks.reshape(m.shape)


def log_decay(A_log, a, dt_bias):
    """log of gated_delta.compute_g."""
    return -mx.exp(A_log.astype(mx.float32)) * nn.softplus(a + dt_bias)


def patch():
    import mlx_lm.models.qwen3_5 as qwen3_5

    original = qwen3_5.gated_delta_update

    def update(q, k, v, a, b, A_log, dt_bias, state=None, mask=None, *, use_kernel=True, **kw):
        if use_kernel or mask is not None or kw.get("lower_bound") is not None:
            return original(q, k, v, a, b, A_log, dt_bias, state, mask, use_kernel=use_kernel, **kw)
        beta = mx.sigmoid(b)
        if kw.get("allow_neg_eigval"):
            beta = beta * 2.0
        return chunked_gated_delta(q, k, v, log_decay(A_log, a, dt_bias), beta, state)

    qwen3_5.gated_delta_update = update
    return original


if __name__ == "__main__":
    # Check against mlx-lm's per-token reference: outputs, final state and gradients.
    mx.random.seed(0)
    # The last case is what real Qwen3.5 activations look like: nearly parallel keys,
    # beta near 1 and slow decay, which makes the WY inverse ill-conditioned.
    for B, T, Hk, Hv, D, hard in [(2, 150, 4, 8, 32, False), (1, 64, 2, 2, 64, False), (1, 7, 2, 4, 32, False),
                                  (1, 200, 2, 4, 64, True)]:
        q = mx.random.normal((B, T, Hk, D)) * 0.1
        k = mx.random.normal((B, T, Hk, D))
        if hard:
            k = mx.random.normal((1, 1, Hk, D)) + 0.05 * k
        k = k / mx.linalg.norm(k, axis=-1, keepdims=True)
        v = mx.random.normal((B, T, Hv, D))
        a = mx.random.normal((B, T, Hv)) - (4.0 if hard else 0.0)
        b = mx.random.normal((B, T, Hv)) + (4.0 if hard else 0.0)
        A_log = mx.log(mx.random.uniform(0.5, 16, (Hv,)))
        dt_bias = mx.ones(Hv)
        s0 = mx.random.normal((B, Hv, D, D)) * 0.1
        w_out = mx.random.normal((B, T, Hv, D))

        def ref(q, k, v, a, b):
            y, s = gd.gated_delta_ops(q, k, v, gd.compute_g(A_log, a, dt_bias), mx.sigmoid(b), s0)
            return y, s

        def new(q, k, v, a, b):
            return chunked_gated_delta(q, k, v, log_decay(A_log, a, dt_bias), mx.sigmoid(b), s0)

        (y1, s1), (y2, s2) = ref(q, k, v, a, b), new(q, k, v, a, b)
        loss = lambda f: lambda *x: (f(*x)[0] * w_out).sum() + f(*x)[1].sum()
        g1 = mx.grad(loss(ref), argnums=(0, 1, 2, 3, 4))(q, k, v, a, b)
        g2 = mx.grad(loss(new), argnums=(0, 1, 2, 3, 4))(q, k, v, a, b)
        rel = lambda x, y: (mx.abs(x - y).max() / (mx.abs(x).max() + 1e-9)).item()
        errors = [rel(y1, y2), rel(s1, s2)] + [rel(x, y) for x, y in zip(g1, g2)]
        print(f"B={B} T={T} Hk={Hk} Hv={Hv} D={D}{' hard' if hard else ''}: y {errors[0]:.2e} state {errors[1]:.2e} "
              f"grads {' '.join(f'{e:.1e}' for e in errors[2:])}")
        # Measured errors are at most about 4e-5; NaN fails too.
        assert all(e <= 1e-3 for e in errors), f"chunked path differs from the reference: {errors}"

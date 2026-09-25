# GalaxigansDeluxe -- the twelve cosmos backdrops as one Metal fragment shader,
# the scene in shader parameter 0. VERBATIM from MACVM (which translated the
# original's HLSL: frac->fract, lerp->mix, aspect from the uniform) but for
# the entry point: Prose's game pane runs it as its background layer, and
# hands it a `pane` -- p.uv, p.size, p.time and p.param(i) -- where MojoCocoa's
# pane handed `fmain` a VOut and Uniforms.

comptime COSMOS_SHADER = String("""float h21(float2 p) { return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453); }

float3 scNebula(float2 uv, float t) {
    float px = uv.x * 640.0, py = uv.y * 360.0;
    float n = sin(px*0.011 + t*0.30) + sin(py*0.014 - t*0.20)
            + sin((px+py)*0.007 + t*0.15) + sin((px-py)*0.009 - t*0.10);
    float neb = (n + 4.0) * 0.125;
    float3 col = float3(0.015 + neb*0.05, 0.010 + neb*0.03, 0.055 + neb*0.20);
    for (int L = 0; L < 3; L++) {
        float sp = 16.0 + float(L)*30.0, cell = 13.0 + float(L)*6.0;
        float2 cp = float2(px, py - t*sp) / cell;
        float2 gi = floor(cp);
        float h = h21(gi);
        if (h > 0.90) {
            float2 sub = fract(cp) - 0.5;
            float d = dot(sub, sub);
            float tw = 0.55 + 0.45*sin(t*3.0 + h*50.0);
            col += saturate(1.0 - d*55.0) * tw * (0.45 + 0.5*float(L));
        }
    }
    return col;
}

float3 scGalaxy(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float r = length(c); float a = atan2(c.y, c.x);
    float spiral = sin(2.0*(a + t*0.15) + 6.5*log(r + 0.06));
    float arm = smoothstep(0.0, 0.7, spiral) * exp(-r*2.6);
    float core = exp(-r*r*38.0);
    float3 col = float3(0.04, 0.02, 0.09);
    col += arm * float3(0.45, 0.40, 0.85) * 0.7;
    col += core * float3(1.0, 0.9, 0.7);
    col += arm * 0.35 * float3(0.8, 0.5, 0.95) * (0.5 + 0.5*sin(r*60.0 - t));
    float2 sg = c*70.0; float2 sgi = floor(sg); float sh = h21(sgi);
    float2 ssb = fract(sg) - 0.5; float sd = dot(ssb, ssb);
    col += (sh > 0.93 ? 1.0 : 0.0) * saturate(1.0 - sd*55.0) * 0.6 * saturate(1.4 - r*2.0);
    return col;
}

float3 scBlack(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float r = length(c); float a = atan2(c.y, c.x);
    float horizon = smoothstep(0.12, 0.105, r);
    float rr = (r - 0.19)*8.5; float ring = exp(-rr*rr);
    float swirl = 0.55 + 0.45*sin(a*3.0 - t*2.2 + 22.0*r);
    float3 disk = ring * swirl * float3(1.0, 0.55, 0.18);
    float2 lp = c * (1.0 + 0.04/(r*r + 0.02));
    float2 sg = lp*72.0; float2 sgi = floor(sg); float sh = h21(sgi);
    float2 ssb = fract(sg) - 0.5; float sd = dot(ssb, ssb);
    float stars = (sh > 0.95 ? 1.0 : 0.0) * saturate(1.0 - sd*45.0) * smoothstep(0.11, 0.15, r);
    float3 col = disk + stars*0.7 + float3(0.02, 0.01, 0.03);
    col *= (1.0 - horizon);
    return col;
}

float3 scAlien(float2 uv, float t, float aspect) {
    float3 sky = mix(float3(0.02,0.05,0.08), float3(0.10,0.03,0.13), uv.y);
    float2 pc = uv - float2(0.5, 1.18); pc.x *= aspect;
    float pr = length(pc); float planet = smoothstep(0.63, 0.62, pr);
    float bands = 0.5 + 0.5*sin(pc.y*34.0 + sin(pc.x*7.0 + t*0.2)*2.2);
    float3 psurf = mix(float3(0.20,0.45,0.18), float3(0.55,0.70,0.30), bands);
    float z = sqrt(saturate(0.40 - pr*pr));
    float lit = saturate(dot(normalize(float3(pc.x, pc.y, z*1.5)),
                             normalize(float3(-0.5, -0.6, 0.6))));
    psurf *= 0.25 + 0.95*lit;
    float3 col = mix(sky, psurf, planet);
    float st = h21(floor(uv * float2(220.0, 130.0)));
    col += (st > 0.985 ? 1.0 : 0.0) * (1.0 - planet) * 0.8;
    float2 mc = uv - float2(0.80, 0.22); mc.x *= aspect; float mr = length(mc);
    float moon = smoothstep(0.05, 0.045, mr);
    float ml = saturate(dot(normalize(float3(mc.x, mc.y, 0.05)),
                            normalize(float3(-0.4, -0.5, 0.7))));
    col = mix(col, float3(0.55,0.52,0.48) * (0.4 + 0.7*ml), moon);
    return col;
}

float craterH(float2 uv) {
    float h = 0.0;
    for (int k = 0; k < 3; k++) {
        float sc = 5.0 * pow(1.8, float(k));
        float2 p = uv*sc; float2 gi = floor(p); float2 gf = fract(p) - 0.5;
        float2 off = float2(h21(gi) - 0.5, h21(gi + 3.3) - 0.5) * 0.5;
        float d = length(gf - off); float rad = 0.16 + 0.16*h21(gi + 7.7);
        float rim = smoothstep(rad + 0.05, rad, d) * smoothstep(rad - 0.06, rad, d);
        float bowl = smoothstep(rad, 0.0, d);
        h += (rim*0.6 - bowl*0.35) / (float(k) + 1.0);
    }
    return h;
}

float3 scMoon(float2 uv, float t, float aspect) {
    float2 uvp = uv + float2(t*0.008, 0.0); uvp.x *= aspect;
    float cr = craterH(uvp);
    float fine = h21(floor(uv * float2(320.0, 180.0))) * 0.05;
    float3 col = float3(0.22,0.22,0.24) + cr*float3(0.55,0.54,0.58) + fine;
    return saturate(col);
}

float3 scNova(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float r = length(c); float a = atan2(c.y, c.x);
    float ph = fract(t*0.12);
    float er = (r - ph*0.75)*7.0; float ring = exp(-er*er);
    float core = exp(-r*r*26.0) * (1.3 - ph);
    float rays = 0.6 + 0.4*sin(a*20.0 + t);
    float3 col = float3(0.05, 0.02, 0.05);
    col += core * float3(1.0, 0.92, 0.7);
    col += ring * float3(1.0, 0.55, 0.25) * rays;
    float st = h21(floor(c*55.0));
    col += (st > 0.95 ? 1.0 : 0.0) * 0.35 * saturate(1.3 - r);
    return col;
}

float3 scWormhole(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float r = length(c) + 0.05; float a = atan2(c.y, c.x);
    float depth = 0.32/r + t*0.6;
    float ring = 0.5 + 0.5*sin(depth*9.0);
    float twist = 0.5 + 0.5*sin(a*6.0 + depth*2.5);
    float3 col = mix(float3(0.02,0.04,0.10), float3(0.20,0.55,0.95), ring*twist);
    col *= saturate(r*2.6);
    col += exp(-r*r*55.0) * float3(0.7, 0.85, 1.0);
    return col;
}

float3 scGasGiant(float2 uv, float t, float aspect) {
    float2 c = uv - float2(0.5, 0.44); c.x *= aspect;
    float r = length(c); float planet = smoothstep(0.32, 0.31, r);
    float lat = c.y/0.33;
    float bands = 0.5 + 0.5*sin(lat*15.0 + sin(lat*4.0 + t*0.1)*1.4);
    float3 surf = mix(float3(0.55,0.42,0.24), float3(0.85,0.72,0.46), bands);
    float2 sp = c - float2(0.11, -0.04);
    float spot = smoothstep(0.06, 0.0, length(sp * float2(1.0, 1.7)));
    surf = mix(surf, float3(0.82,0.32,0.20), spot*0.7);
    float z = sqrt(saturate(0.105 - r*r));
    float lit = saturate(dot(normalize(float3(c.x, c.y, z*3.0)),
                             normalize(float3(-0.5, -0.3, 0.8))));
    surf *= 0.30 + 0.9*lit;
    float2 rc = c * float2(1.0, 3.4); float rr = length(rc);
    float ring = smoothstep(0.40, 0.43, rr) * smoothstep(0.60, 0.57, rr)
               * (0.55 + 0.45*sin(rr*90.0));
    float3 col = float3(0.02, 0.02, 0.05);
    float st = h21(floor(uv * float2(220.0, 130.0)));
    col += (st > 0.985 ? 1.0 : 0.0) * 0.7;
    col = mix(col, float3(0.75,0.68,0.52), ring * (1.0 - planet));
    col = mix(col, surf, planet);
    return col;
}

float3 scAurora(float2 uv, float t) {
    float3 col = float3(0.01, 0.02, 0.05);
    float st = h21(floor(uv * float2(200.0, 120.0)));
    col += (st > 0.98 ? 1.0 : 0.0) * 0.6 * smoothstep(0.55, 0.0, uv.y);
    float fil = 0.62 + 0.38*sin(uv.x*140.0 + sin(uv.y*8.0)*2.0 + t*1.5);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float cx = 0.18 + fi*0.22 + 0.13*sin(uv.y*3.0 + t*0.4 + fi*1.7);
        float fx = (uv.x - cx)*11.0; float band = exp(-fx*fx);
        float hh = smoothstep(0.04, 0.42, uv.y) * (1.0 - smoothstep(0.50, 0.96, uv.y));
        float3 ac = mix(float3(0.1,0.95,0.45), float3(0.45,0.2,0.9), fract(fi*0.37));
        col += band * hh * fil * ac * 0.75;
    }
    return col;
}

float3 scPulsar(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float r = length(c); float a = atan2(c.y, c.x);
    float core = exp(-r*r*70.0);
    float beam = pow(abs(cos(a - t*1.5)), 40.0) + pow(abs(cos(a - t*1.5 + 3.14159)), 40.0);
    beam *= exp(-r*1.6);
    float3 col = float3(0.02, 0.03, 0.06);
    col += core * float3(0.85, 0.92, 1.0);
    col += beam * float3(0.45, 0.65, 1.0);
    float st = h21(floor(c*60.0));
    col += (st > 0.97 ? 1.0 : 0.0) * 0.45;
    return col;
}

float3 scPlasma(float2 uv, float t) {
    float px = uv.x*6.0, py = uv.y*4.0;
    float v = sin(px + t) + sin(py*1.3 - t*0.7) + sin((px+py)*0.8 + t*0.5)
            + sin(length(float2(px, py) - 3.0)*2.2 - t);
    float3 col = 0.5 + 0.5*cos(float3(v, v + 2.1, v + 4.2));
    col *= float3(0.42, 0.30, 0.52);
    return col;
}

float3 scBinary(float2 uv, float t, float aspect) {
    float2 c = uv - 0.5; c.x *= aspect;
    float2 s1 = float2(cos(t*0.4), sin(t*0.4)) * 0.16;
    float2 s2 = -s1;
    float d1 = length(c - s1), d2 = length(c - s2);
    float3 col = float3(0.02, 0.02, 0.05);
    col += exp(-d1*d1*150.0)*float3(1.0,0.8,0.5) + exp(-d1*9.0)*float3(0.35,0.25,0.12);
    col += exp(-d2*d2*150.0)*float3(0.6,0.8,1.0) + exp(-d2*9.0)*float3(0.16,0.26,0.4);
    float st = h21(floor(c*52.0));
    col += (st > 0.97 ? 1.0 : 0.0) * 0.4;
    return col;
}

float3 background(pane p) {
    float t = p.time;
    int sc = int(p.param(0) + 0.5);
    float2 uv = p.uv;
    float a = p.size.x / p.size.y;
    float3 col;
    if (sc == 1) col = scGalaxy(uv, t, a);
    else if (sc == 2) col = scBlack(uv, t, a);
    else if (sc == 3) col = scAlien(uv, t, a);
    else if (sc == 4) col = scMoon(uv, t, a);
    else if (sc == 5) col = scNova(uv, t, a);
    else if (sc == 6) col = scWormhole(uv, t, a);
    else if (sc == 7) col = scGasGiant(uv, t, a);
    else if (sc == 8) col = scAurora(uv, t);
    else if (sc == 9) col = scPulsar(uv, t, a);
    else if (sc == 10) col = scPlasma(uv, t);
    else if (sc == 11) col = scBinary(uv, t, a);
    else col = scNebula(uv, t);
    return col;
}""")

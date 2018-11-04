function defaultfcn(z)
      f = 1e9
      ϵᵣ = 5 - 2im
      μᵣ = 1 - 2im
      d = 1e-2
      c = 3e8
      ω = 2π*f
      k₀ = ω/c
      cc = ϵᵣ^2*(k₀*d)^2*(ϵᵣ*μᵣ - 1)
      w = ϵᵣ^2*z^2 + z^2*tan(z)^2 - cc
end

# Analysis parameters
xb = -2.  # real part begin
xe = 2.  # real part end
yb = -2.  # imag part begin
ye = 2.  # imag part end
r = 0.2  # initial mesh step
tolerance = 1e-9

origcoords = rectangulardomain(complex(xb, yb), complex(xe, ye), r)

rmin, rmax = minimum(real(origcoords)), maximum(real(origcoords))
imin, imax = minimum(imag(origcoords)), maximum(imag(origcoords))

ra = (max_coord-min_coord)/(rmax-rmin)
rb = max_coord - ra*rmax

ia = (max_coord-min_coord)/(imax-imin)
ib = max_coord - ia*imax

origcoords = mapfunctionval.(origcoords, ra, rb, ia, ib)
newnodes = [IndexablePoint2D(real(coord), imag(coord), idx) for (idx, coord) in enumerate(origcoords)]
tess = DelaunayTessellation2D{IndexablePoint2D}(2000)

tess, 𝓔, quadrants = GRPF.tesselate!(tess, newnodes, pt -> defaultfcn(geom2fcn(pt, ra, rb, ia, ib)),
                                   e -> geom2fcn(e, ra, rb, ia, ib), tolerance)

𝐶 = GRPF.contouredges(tess, 𝓔)
regions = GRPF.evaluateregions!(𝐶, e -> geom2fcn(e, ra, rb, ia, ib))

zroots, zroots_multiplicity, zpoles, zpoles_multiplicity = GRPF.rootsandpoles(regions, quadrants, e -> geom2fcn(e, ra, rb, ia, ib))

sort!(zroots, by = x -> (real(x), imag(x)))
sort!(zpoles, by = x -> (real(x), imag(x)))

@test length(zroots) == 6
@test length(zpoles) == 2

@test zroots[1] ≈ -1.624715288135189 + 0.182095877702038im
@test zroots[2] ≈ -1.520192978034417 - 0.173670452237129im
@test zroots[3] ≈ -0.515113098919392 + 0.507111597359180im
@test zroots[4] ≈ 0.515113098795215 - 0.507111597284675im
@test zroots[5] ≈ 1.520192978034417 + 0.173670452237129im
@test zroots[6] ≈ 1.624715288135189 - 0.182095877702037im

@test zpoles[1] ≈ -1.570796326699632 - 0.000000000206961im
@test zpoles[2] ≈ 1.570796326699632 - 0.000000000206961im

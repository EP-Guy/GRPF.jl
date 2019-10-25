# GRPF.jl: Global complex Roots and Poles Finding in Julia

A Julia implementation of [GRPF](https://github.com/PioKow/GRPF) by Dr. Piotr Kowalczyk. Please consider citing Piotr's publications if this code is used in scientific work:

  1. P. Kowalczyk, “Complex Root Finding Algorithm Based on Delaunay Triangulation”, ACM Transactions on Mathematical Software, vol. 41, no. 3, art. 19, pp. 1-13, June 2015. https://dl.acm.org/citation.cfm?id=2699457
  2. P. Kowalczyk, "Global Complex Roots and Poles Finding Algorithm Based on Phase Analysis for Propagation and Radiation Problems," IEEE Transactions on Antennas and Propagation, vol. 66, no. 12, pp. 7198-7205, Dec. 2018. https://ieeexplore.ieee.org/document/8457320

## Description

GRPF attempts to **find all the zeros and poles of a (complex) function in a fixed region**. These types of problems are frequently encountered in electromagnetic waveguides, but the algorithm can also be used for similar problems.

GRPF first samples the function on a regular triangular mesh through Delaunay triangulation. Candidate regions to search for roots and poles are determined and the discretized Cauchy's argument is applied _without needing the derivative of the function or integration over the contour_. To improve the accuracy of the results, a self-adaptive mesh refinement occurs inside the identified candidate regions.

## Usage

TODO

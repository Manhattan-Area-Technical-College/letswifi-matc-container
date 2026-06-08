# letswifi-matc-container
## Disclaimer

This project is an independent effort by Manhattan Area Technical College (MATC).

It is **not affiliated with, endorsed by, or supported by**:
- LetsWiFi  
- geteduroam  
- eduroam  
- GÉANT  

All product names, trademarks, and registered trademarks are the property of their respective owners.
## Overview

`manhattantech-letswifi-container` provides an **OCI container image** for the upstream **LetsWiFi** project.

Instead of relying on install scripts that target specific platforms, this project packages LetsWiFi into a **portable, reproducible container image**, with the intent to run it similar to how we do our other software and run it on our RHEL systems, with a side benefit of hopefully making this a lot easier for other institutions to run. 


## Authors and Contributors

- Bryanna Marihugh – Project author and maintainer

## AI Policy

We are still in the early days, but over the last 6 months it has become clear the tools are acceptable if watched carefully. If anyone else contributes they can be used, just review and know what your adding does. I used it to help organize some of the documentation and help with where my PHP skills were weak and especially the crl generation script. I also tend to let it review all my commits helps me catch my human errors. 

## Licensing

### This Project

Copyright (c) 2026 Manhattan Area Technical College

Licensed under the MIT License.

This repository contains containerization, deployment tooling, and
configuration for LetsWiFi Portal.

---

### Upstream Software

This project redistributes LetsWiFi Portal:

https://github.com/geteduroam/letswifi-portal

Licensed under the BSD 3-Clause License.

Copyright (c) 2020 Jørn Åne de Jong, Uninett AS

See `/licenses/letswifi-portal/LICENSE` for the full license text.

---

This project also redistributes SimpleSAMLphp:

https://github.com/simplesamlphp/simplesamlphp

Licensed under the GNU Lesser General Public License v2.1.

Copyright (c) 2007-2020 UNINETT AS, 2021-2024 SimpleSAMLphp

See `/licenses/simplesamlphp/LICENSE` for the full license text.

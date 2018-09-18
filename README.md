This git repository contains the various scripts used in the CentOS Infra for mirrorlist service and isoredirect service.
It contains the following kind of scripts:

 * backend : so scripts used by our "crawler" node, validating in loop all the external mirrors through IPv4 and IPv6 and so producing the 'mirrorlists', each one per repo/arch/country
 * frontend : python scripts used for :
  * http://mirrorlist.centos.org
  * http://isoredirect.centos.org

## Backend (crawler)
Place holder for doc

## Frontend 
All scripts are located in the frontend folder.
The following items are needed for the mirrorlist/isoredirect service:

 * A http server (apache) using mod_proxy_balancer (see frontend/httpd/mirrorlist.conf vhost example)
 * python-bottle to run the {ml,isoredirect}.py code for various instances
 * Maxmind GeoIP2 database (City version)
 * For each worker, a specific instance/port can be initialized and added to Apache config for the proxy-balancer (see frontend/systemd/centos-ml-worker@.service)



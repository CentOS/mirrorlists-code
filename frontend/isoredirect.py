#!/usr/bin/python
from bottle import route, run, request, template, response
from bottle import PasteServer, static_file
import os
import geoip2.database
import ipaddr
import json
import time

# Json file holding the nearby countries list, generated from geo_cc.pm with convert_ccgroups_to_json.pl
ccgroups_file = 'ccgroups.json'
geodb = geoip2.database.Reader('/usr/share/GeoIP/GeoLite2-City.mmdb')

with open(ccgroups_file) as ccgroupjson:
  ccgroups = json.load(ccgroupjson)

@route('/<branch:re:(centos|altarch)>/<release:re:[6789](\.[0-9.]+)?>/isos/<arch:re:(x86_64|aarch64|armhfp|i386|power9|ppc64(le)?)/?><filename:re:[-A-Za-z0-9._]*>')
def home(branch, release, arch, filename):
  ip=request.remote_route[-1]
  cc=request.query.cc
  debug=request.query.debug
  remote_ip = ipaddr.IPAddress(ip)
  mirrorlistpage = "https://www.centos.org/download/mirrors/"
  if branch == "altarch":
    mirrorlistpage = "https://www.centos.org/download/altarch-mirrors/"

  region = None
  if len(cc) == 5 and cc[2:3] == "-":
    country = cc[:2]
    region = cc[3:]
  elif len(cc) > 0:
    country = cc
  else:
    try:
      country = geodb.city(ip).country.iso_code.lower()
      if country == 'us' or country == 'ca':
        try:
          region = geodb.city(ip).subdivisions.most_specific.iso_code
        except:
          pass
    except:
      country = 'fallback'
  arch = arch.replace("/", "")
  filename = filename.replace("/", "")

  # make sure the request is valid by checking if there is a fallback file (there should always be one)
  if len(filename) > 0:
    mirrorlist_fallback = 'ipv4/%s/%s/isos/%s/%s.fallback' % (branch, release, arch, filename)
  else:
    mirrorlist_fallback = 'ipv4/%s/%s/isos/%s/iso.fallback' % (branch, release, arch)

  if not os.path.isfile('views/%s' % (mirrorlist_fallback)):
    response.status=404
    return template("isoredirect.tpl", content='The requested branch/release/arch/filename does not seem to be valid, please check your input')

  lastchecked = time.ctime(os.path.getmtime('views/%s' % (mirrorlist_fallback)))

  debugtext = ""
  if len(debug) > 0:
    debug_region = ""
    if region is not None:
      debug_region=region
    debugtext = "Debugging: Your IP address is %s, and we think your country is &lt;%s&gt; and your subregion is &lt;%s&gt;<br><br>\n" % (remote_ip, country, debug_region)

  content = "%s<b>In order to conserve the limited bandwidth available, ISO images are not downloadable from mirror.centos.org<br><br>\n" % (debugtext)
  footer = "<br><br>Mirrors verified %s UTC<br><br>\
You can also download the ISO images using <a href='https://en.wikipedia.org/wiki/BitTorrent'>bittorrent</a>, a peer-to-peer file sharing protocol. The .torrent files can be found from CentOS mirrors. \
Various bittorrent clients are available, including (in no particular order of preference): utorrent, vuze (Azureus), BitTorrent, Deluge, ctorrent, ktorrent, rtorrent and transmission. \
Packaged copies of various torrent clients for CentOS can be found in the repositories listed in the following wiki article: \
<a href='https://wiki.centos.org/AdditionalResources/Repositories'>https://wiki.centos.org/AdditionalResources/Repositories</a>" % (lastchecked)

  # if using curl/wget and requesting a file, redirect immediately to the first mirror
  fast_redirect = False
  try:
    agent = request.environ.get('HTTP_USER_AGENT')[:5].lower()
    if (agent == "curl/" or agent == "wget/") and filename != "":
      fast_redirect = True
  except:
    pass

  # build a list of regions to check
  try:
    if region is not None:
      countrylist = [ country + "-" + region ] + ccgroups[country] + [ "fallback" ]
    else:
      countrylist = ccgroups[country] + [ "fallback" ]
  except:
    countrylist = [ "fallback" ]

  number_of_urls = 0;
  header_printed = False
  mirrors_from_primary_region = False

  seen = {}
  for i in range(0, len(countrylist)):
    c = countrylist[i]

    if len(filename) > 0:
      mirrorlist_file = 'ipv4/%s/%s/isos/%s/%s.%s' % (branch, release, arch, filename, c)
    else:
      mirrorlist_file = 'ipv4/%s/%s/isos/%s/iso.%s' % (branch, release, arch, c)

    try:
      if os.path.isfile('views/%s' % (mirrorlist_file)):
        if i == 0 and c != "fallback":
          content += 'The following mirrors in your region should have the ISO images available:</b><br><br>\n'
          header_printed = True
          mirrors_from_primary_region = True
        if not header_printed:
          content += 'The following mirrors should have the ISO images available:</b><br><br>\n'
          header_printed = True
        with open('views/%s' % (mirrorlist_file)) as fh:
          for line in fh:
            line = line.strip()
            if fast_redirect:
              response.status = 302
              response.set_header("Location", line)
              return
            if not seen.has_key(line):
              seen[line] = True
              content += "<a href='%s'>%s</a><br>\n" % (line, line)
              number_of_urls += 1
              if number_of_urls == 30:
                return template("isoredirect.tpl", content=content + "+ others, see the full list of mirrors: <a href='%s'>%s</a>%s" % (mirrorlistpage, mirrorlistpage, footer))
    except:
      # if something goes wrong, don't make noise about it
      pass

    if number_of_urls >= 25 and i == 0:
      # 25..29 mirrors is also a sufficient number, let's not add more from other countries
      return template("isoredirect.tpl", content=content + "+ others, see the full list of mirrors: <a href='%s'>%s</a>%s" % (mirrorlistpage, mirrorlistpage, footer))

    if i == 0 and mirrors_from_primary_region:
      content += "<br>Other mirrors further away:<br><br>\n"

  return template("isoredirect.tpl", content=content + footer)


# alternatively, arrange the web server config so that these static files are served by the web server
@route('/<pth:re:(favicon|HEADER.images).*>')
def files(pth):
  return static_file(pth, root='.')


@route('/<pth:re:.*>')
def nothere(pth):
  if pth != "":
    # make sure invalid URLs won't be indexed by web crawlers
    response.status=404
  return template("isoredirect.tpl", content="\
To use the CentOS ISO Redirect Service, please include the directory in the URL. Some examples:<br><ul>\
<li><b><a href='/centos/7/isos/x86_64/'>http://isoredirect.centos.org/centos/7/isos/x86_64/</a></b> for CentOS 7 x86_64 iso images<br>\
<li><b><a href='/altarch/7/isos/ppc64le/'>http://isoredirect.centos.org/altarch/7/isos/ppc64le/</a></b> for CentOS 7 AltArch ppc64le iso images<br>\
<li><b><a href='/altarch/7/isos/armhfp/'>http://isoredirect.centos.org/altarch/7/isos/armhfp/</a></b> for CentOS 7 AltArch armhfp disk images<br>\
<li><b><a href='/centos/6/isos/x86_64/'>http://isoredirect.centos.org/centos/6/isos/x86_64/</a></b> for CentOS 6 x86_64 iso images<br>\
<li><b><a href='/centos/6/isos/i386/'>http://isoredirect.centos.org/centos/6/isos/i386/</a></b> for CentOS 6 i386 iso images<br>\
</ul>")
  
run(server=PasteServer, port=8000, debug=False, reloader=True)

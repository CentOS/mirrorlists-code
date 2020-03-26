#!/usr/bin/python
from bottle import route, run, request, template, response
from bottle import PasteServer, static_file
import os
import geoip2.database
import ipaddr
import json
import time

geodb = geoip2.database.Reader('/usr/share/GeoIP/GeoLite2-City.mmdb')

# list of cli tools for which we'll just directly redirect instead of giving a list
cli_user_agents= [ 'curl', 'wget', 'packer', 'ansible-httpget' ]

# Json file holding the nearby countries list, generated from geo_cc.pm with convert_ccgroups_to_json.pl
with open('ccgroups.json') as ccgroupjson:
  ccgroups = json.load(ccgroupjson)

# Json file holding automatically generated additional nearby countries, generated with create_additional_countries.py
try:
  with open('additional_countries.json') as additionalcountriesjson:
    additional_countries = json.load(additionalcountriesjson)
  for addcc in additional_countries:
    # append the additional countries to ccgroups
    if ccgroups.has_key(addcc):
      ccgroups[addcc] = ccgroups[addcc] + additional_countries[addcc]
    else:
      ccgroups[addcc] = [addcc] + additional_countries[addcc]
except:
  # this is only a "nice to have" list
  pass

@route('/<branch:re:(centos|altarch)>/<release:re:8-stream|[6789](\.[0-9.]+)?>/<filetype:re:(isos|images)>/<arch:re:(x86_64|aarch64|armhfp|i386|power9|ppc64(le)?)/?><filename:re:[-A-Za-z0-9._]*>')
def home(branch, release, filetype, arch, filename):
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
    mirrorlist_fallback = 'ipv4/%s/%s/%s/%s/%s.fallback' % (branch, release, filetype, arch, filename)
  else:
    mirrorlist_fallback = 'ipv4/%s/%s/%s/%s/iso.fallback' % (branch, release, filetype, arch)

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
    agent = request.environ.get('HTTP_USER_AGENT').lower()
    for cli in cli_user_agents:
      if cli in agent:
        fast_redirect = True
        break
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
      mirrorlist_file = 'ipv4/%s/%s/%s/%s/%s.%s' % (branch, release, filetype, arch, filename, c)
    else:
      mirrorlist_file = 'ipv4/%s/%s/%s/%s/iso.%s' % (branch, release, filetype, arch, c)

    try:
      if os.path.isfile('views/%s' % (mirrorlist_file)):
        if i == 0 and c != "fallback":
          content += '<div class="alert alert-success" role="alert">The following mirrors in your region should have the ISO images available:</b><br></div>\n'
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
      content += '<br><div class="alert alert-info" role="alert"><b>Other mirrors further away:</b></div>\n'

  return template("isoredirect.tpl", content=content + footer)


# alternatively, arrange the web server config so that these static files are served by the web server
@route('/<pth:re:(favicon|HEADER.images|centos-design).*>')
def files(pth):
  return static_file(pth, root='.')


@route('/<pth:re:.*>')
def nothere(pth):
  if pth != "":
    # make sure invalid URLs won't be indexed by web crawlers
    response.status=404
  return template("isoredirect.tpl", content="\
<div class='alert alert-info' role='alert'>\n\
<b>To use the CentOS ISO Redirect Service, please include the directory in the URL. </b><br>\n\
Some examples:\n\
</div>\n\
<table border=0>\n\
<tr><td><b><a href='/centos/8-stream/isos/x86_64/'>http://isoredirect.centos.org/centos/8-stream/isos/x86_64/</a></b></td><td>for CentOS Stream x86_64 iso images</td></tr>\n\
<tr><td><b><a href='/centos/8/isos/x86_64/'>http://isoredirect.centos.org/centos/8/isos/x86_64/</a></b></td><td>for CentOS 8 x86_64 iso images</td></tr>\n\
<tr><td><b><a href='/centos/8-stream/isos/aarch64/'>http://isoredirect.centos.org/centos/8-stream/isos/aarch64/</a></b></td><td>for CentOS Stream aarch64 iso images</td></tr>\n\
<tr><td><b><a href='/centos/8/isos/aarch64/'>http://isoredirect.centos.org/centos/8/isos/aarch64/</a></b></td><td>for CentOS 8 aarch64 iso images</td></tr>\n\
<tr><td><b><a href='/centos/8-stream/isos/ppc64le/'>http://isoredirect.centos.org/centos/8-stream/isos/ppc64le/</a></b></td><td>for CentOS Stream ppc64le iso images</td></tr>\n\
<tr><td><b><a href='/centos/8/isos/ppc64le/'>http://isoredirect.centos.org/centos/8/isos/ppc64le/</a></b></td><td>for CentOS 8 ppc64le iso images</td></tr>\n\
<tr><td><b><a href='/centos/7/isos/x86_64/'>http://isoredirect.centos.org/centos/7/isos/x86_64/</a></b></td><td>for CentOS 7 x86_64 iso images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/aarch64/'>http://isoredirect.centos.org/altarch/7/isos/aarch64/</a></b></td><td>for CentOS 7 AltArch AArch64 iso images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/armhfp/'>http://isoredirect.centos.org/altarch/7/isos/armhfp/</a></b></td><td>for CentOS 7 AltArch armhfp disk images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/i386/'>http://isoredirect.centos.org/altarch/7/isos/i386/</a></b></td><td>for CentOS 7 AltArch i386 iso images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/power9/'>http://isoredirect.centos.org/altarch/7/isos/power9/</a></b></td><td>for CentOS 7 AltArch POWER9 iso images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/ppc64/'>http://isoredirect.centos.org/altarch/7/isos/ppc64/</a></b></td><td>for CentOS 7 AltArch ppc64 iso images</td></tr>\n\
<tr><td><b><a href='/altarch/7/isos/ppc64le/'>http://isoredirect.centos.org/altarch/7/isos/ppc64le/</a></b></td><td>for CentOS 7 AltArch ppc64le iso images</td></tr>\n\
<tr><td><b><a href='/centos/6/isos/x86_64/'>http://isoredirect.centos.org/centos/6/isos/x86_64/</a></b></td><td>for CentOS 6 x86_64 iso images</td></tr>\n\
<tr><td><b><a href='/centos/6/isos/i386/'>http://isoredirect.centos.org/centos/6/isos/i386/</a></b></td><td>for CentOS 6 i386 iso images</td></tr>\n\
</table>")
  
run(server=PasteServer, port=8000, debug=False, reloader=True)

#!/usr/bin/python
import bottle
from bottle import route, run, request, abort, template, response
from bottle import PasteServer
from time import sleep
import os
import geoip2.database
import ipaddr
import json

# Json file holding all repositories/paths
repo_file = '/var/lib/centos-mirrorlist/views/repos.json'
geodb = geoip2.database.Reader('/usr/share/GeoIP/GeoLite2-City.mmdb')

with open(repo_file) as repos:
  paths = json.load(repos)

@route('/')
def home():
  release=request.query.release
  arch=request.query.arch
  repo=request.query.repo.lower()
  ip=request.remote_route[-1]
  cc=request.query.cc
  response.content_type = 'text/plain'

  remote_ip = ipaddr.IPAddress(ip)
  ip_ver = remote_ip.version
  ipver = 'ipv'+str(ip_ver)

  if not arch:
    return 'arch not specified\n'
  if not repo:
    return 'repo not specified\n'
  if not release:
    return 'release not specified\n'

  if len(cc) > 0:
    country = cc
  else:
    try:
      country = geodb.city(ip).country.iso_code.lower()
      if country == 'us' or country == 'ca':
        try:
          region = geodb.city(ip).subdivisions.most_specific.iso_code
        except:
          pass
        else:
          if region is not None and len(region) == 2:          
            country = country + '-' + region
    except:
      country = 'fallback'
  try:
    mirrorlist_file = '%s/%s/%s/%s/mirrorlists/mirrorlist.%s' % (ipver,paths[release][repo][arch]["branch"],release,paths[release][repo][arch]["path"],country)
    mirrorlist_fallback = '%s/%s/%s/%s/mirrorlists/mirrorlist.fallback' % (ipver,paths[release][repo][arch]["branch"],release,paths[release][repo][arch]["path"])
  except:
    return 'Invalid release/repo/arch combination\n'

  bottle.TEMPLATES.clear() 

  # build a list of possible mirrorlists to return, in order of preference
  lists = []
  if os.path.isfile('views/%s' % (mirrorlist_file)):
    lists.append(mirrorlist_file)
  if (country[:3] == 'us-' or country[:3] == 'ca-') and os.path.isfile('views/%s' % (mirrorlist_file[:-3])):
    lists.append(mirrorlist_file[:-3])
  if os.path.isfile('views/%s' % (mirrorlist_fallback)):
    lists.append(mirrorlist_fallback)

  for tn in lists:
    for retries in range(1,2):
      try:
        return template(tn)
      except:
        sleep(0.1)

  # if we got this far:
  # - the repo exists (if not, it would have been caught earlier), and despite this,
  # - mirrorlists were unavailable, so
  # -> return something useful and hope for the best
  return 'http://mirror.centos.org/%s/%s/%s/\n' % (paths[release][repo][arch]["branch"], release, paths[release][repo][arch]["path"])

@route('/<pth:re:.*>')
def nothere(pth):
  abort(404, "Nothing to see here..")

run(server=PasteServer, port=8000, debug=False, reloader=True)


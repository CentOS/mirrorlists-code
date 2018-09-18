#!/usr/bin/python
import bottle
from bottle import route, run, request, abort, template, response
from bottle import PasteServer
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
  repo=request.query.repo
  ip=request.remote_route[-1]
  cc=request.query.cc

  remote_ip = ipaddr.IPAddress(ip)
  ip_ver = remote_ip.version
  ipver = 'ipv'+str(ip_ver)

  if not arch:
    return 'arch not specified'
  if not repo:
    return 'repo not specified'
  if not release:
    return 'release not specified'

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
  except:
    return 'Invalid release/repo/arch combination or unknown country %s' % (country)
  try:
    mirrorlist_fallback = '%s/%s/%s/%s/mirrorlists/mirrorlist.fallback' % (ipver,paths[release][repo][arch]["branch"],release,paths[release][repo][arch]["path"])
  except:
    return 'Invalid release/repo/arch combination and no fallback'

  if os.path.isfile('views/%s' % (mirrorlist_file)):
    tn=mirrorlist_file
  elif (country[:3] == 'us-' or country[:3] == 'ca-') and os.path.isfile('views/%s' % (mirrorlist_file[:-3])):
    tn=mirrorlist_file[:-3]
  elif os.path.isfile('views/%s' % (mirrorlist_fallback)):
    tn=mirrorlist_fallback
  else:
    return 'Invalid release/repo/arch combination or no mirrorlist.fallback'
     
  
  response.content_type= 'text/plain'
  bottle.TEMPLATES.clear() 
  return template(tn, rel=release, repo=repo, arch=arch)

@route('/<pth:re:.*>')
def nothere(pth):
  abort(404, "Nothing to see here..")

run(server=PasteServer, port=8000, debug=False, reloader=True)


#!/usr/bin/python
from __future__ import unicode_literals
import bottle
from bottle import route, run, request, abort, template, response
from bottle import PasteServer
from time import sleep
import os
import geoip2.database
import ipaddr
import ipaddress
import json
import memcache

# Json file holding all repositories/paths
geodb = geoip2.database.Reader('/usr/share/GeoIP/GeoLite2-City.mmdb')
repo_file = '/var/lib/centos-mirrorlist/views/repos.json'
mc = memcache.Client(['127.0.0.1:11211'], debug=0)
# If we can identify cloud provider subnet and which ones we current support
cloud_providers = ['ec2']
clouds_subnets_file = '/var/lib/centos-mirrorlist/clouds_subnets.json'

with open(repo_file) as repos:
  paths = json.load(repos)

with open(clouds_subnets_file) as clouds_subnets:
  providers_subnets = json.load(clouds_subnets)

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

  # Checking first in memcache
  try:
    mc_value = mc.get(str(remote_ip))
  except:
    mc_value = None

  # Checking memcache status and redirect to correct snippet
  if mc_value in cloud_providers:
    mirrorlist = ""
    try:
      for baseurl in providers_subnets[mc_value]['baseurl']:
        mirrorlist += '%s/%s/%s/%s/\n' % (baseurl,paths[release][repo][arch]["branch"], release, paths[release][repo][arch]["path"])
      return mirrorlist
    except:
      return 'Invalid release/repo/arch combination\n'
  elif mc_value is None:
    # Checking first if we're coming from known cloud provider and if so, not using geoip
    for provider in cloud_providers:
      for subnet in providers_subnets[provider][ipver]:
        if ipaddress.ip_address(remote_ip) in ipaddress.ip_network(subnet):
          mirrorlist = ""
          try:
            mc.set(str(remote_ip),provider)
          except:
            pass
          try:
            for baseurl in providers_subnets[provider]['baseurl']:
							mirrorlist += '%s/%s/%s/%s/\n' % (baseurl,paths[release][repo][arch]["branch"], release, paths[release][repo][arch]["path"])
            return mirrorlist
          except:
            return 'Invalid release/repo/arch combination\n'
          break

    if len(cc) > 0:
      country = cc
    else:
      try:
        country = geodb.city(ip).country.iso_code.lower()
        try:
          mc.set(str(ip),country)
        except:
          print 'error inserting into memcache'
          pass
        if country == 'us' or country == 'ca':
          try:
            region = geodb.city(ip).subdivisions.most_specific.iso_code
          except:
            print 'unable to find region' 
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
  # We got a country from memcache so not doing cloud checks nor geoiplookup and using cache
  else:
    # Still checking if we got cc as variable
    if len(cc) > 0:
      country = cc
    else:
      country = str(mc_value)
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


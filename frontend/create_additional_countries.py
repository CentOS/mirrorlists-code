#!/usr/bin/python
import json
from math import radians, sin, cos, acos

#
# this script creates a list of countries that are <= 5000 km away from each country
# (or <= 8000 km for really remote countries)
#

# countries already listed in ccgroups will not be included in the additional countries list
ccgroups_file = 'ccgroups.json'
with open(ccgroups_file) as ccgroupjson:
  ccgroups = json.load(ccgroupjson)

# list of coordinates for each country
# based on https://developers.google.com/public-data/docs/canonical/countries_csv
coords = { 
  "ad":[42.546245,1.601554],
  "ae":[23.424076,53.847818],
  "af":[33.93911,67.709953],
  "ag":[17.060816,-61.796428],
  "ai":[18.220554,-63.068615],
  "al":[41.153332,20.168331],
  "am":[40.069099,45.038189],
  "an":[12.226079,-69.060087],
  "ao":[-11.202692,17.873887],
  "aq":[-75.250973,-0.071389],
  "ar":[-38.416097,-63.616672],
  "as":[-14.270972,-170.132217],
  "at":[47.516231,14.550072],
  "au":[-25.274398,133.775136],
  "aw":[12.52111,-69.968338],
  "az":[40.143105,47.576927],
  "ba":[43.915886,17.679076],
  "bb":[13.193887,-59.543198],
  "bd":[23.684994,90.356331],
  "be":[50.503887,4.469936],
  "bf":[12.238333,-1.561593],
  "bg":[42.733883,25.48583],
  "bh":[25.930414,50.637772],
  "bi":[-3.373056,29.918886],
  "bj":[9.30769,2.315834],
  "bm":[32.321384,-64.75737],
  "bn":[4.535277,114.727669],
  "bo":[-16.290154,-63.588653],
  "br":[-14.235004,-51.92528],
  "bs":[25.03428,-77.39628],
  "bt":[27.514162,90.433601],
  "bv":[-54.423199,3.413194],
  "bw":[-22.328474,24.684866],
  "by":[53.709807,27.953389],
  "bz":[17.189877,-88.49765],
  "ca":[56.130366,-106.346771],
  "cc":[-12.164165,96.870956],
  "cd":[-4.038333,21.758664],
  "cf":[6.611111,20.939444],
  "cg":[-0.228021,15.827659],
  "ch":[46.818188,8.227512],
  "ci":[7.539989,-5.54708],
  "ck":[-21.236736,-159.777671],
  "cl":[-35.675147,-71.542969],
  "cm":[7.369722,12.354722],
  "cn":[35.86166,104.195397],
  "co":[4.570868,-74.297333],
  "cr":[9.748917,-83.753428],
  "cu":[21.521757,-77.781167],
  "cv":[16.002082,-24.013197],
  "cx":[-10.447525,105.690449],
  "cy":[35.126413,33.429859],
  "cz":[49.817492,15.472962],
  "de":[51.165691,10.451526],
  "dj":[11.825138,42.590275],
  "dk":[56.26392,9.501785],
  "dm":[15.414999,-61.370976],
  "do":[18.735693,-70.162651],
  "dz":[28.033886,1.659626],
  "ec":[-1.831239,-78.183406],
  "ee":[58.595272,25.013607],
  "eg":[26.820553,30.802498],
  "eh":[24.215527,-12.885834],
  "er":[15.179384,39.782334],
  "es":[40.463667,-3.74922],
  "et":[9.145,40.489673],
  "fi":[61.92411,25.748151],
  "fj":[-16.578193,179.414413],
  "fk":[-51.796253,-59.523613],
  "fm":[7.425554,150.550812],
  "fo":[61.892635,-6.911806],
  "fr":[46.227638,2.213749],
  "ga":[-0.803689,11.609444],
  "gb":[55.378051,-3.435973],
  "gd":[12.262776,-61.604171],
  "ge":[42.315407,43.356892],
  "gf":[3.933889,-53.125782],
  "gg":[49.465691,-2.585278],
  "gh":[7.946527,-1.023194],
  "gi":[36.137741,-5.345374],
  "gl":[71.706936,-42.604303],
  "gm":[13.443182,-15.310139],
  "gn":[9.945587,-9.696645],
  "gp":[16.995971,-62.067641],
  "gq":[1.650801,10.267895],
  "gr":[39.074208,21.824312],
  "gs":[-54.429579,-36.587909],
  "gt":[15.783471,-90.230759],
  "gu":[13.444304,144.793731],
  "gw":[11.803749,-15.180413],
  "gy":[4.860416,-58.93018],
  "gz":[31.354676,34.308825],
  "hk":[22.396428,114.109497],
  "hm":[-53.08181,73.504158],
  "hn":[15.199999,-86.241905],
  "hr":[45.1,15.2],
  "ht":[18.971187,-72.285215],
  "hu":[47.162494,19.503304],
  "id":[-0.789275,113.921327],
  "ie":[53.41291,-8.24389],
  "il":[31.046051,34.851612],
  "im":[54.236107,-4.548056],
  "in":[20.593684,78.96288],
  "io":[-6.343194,71.876519],
  "iq":[33.223191,43.679291],
  "ir":[32.427908,53.688046],
  "is":[64.963051,-19.020835],
  "it":[41.87194,12.56738],
  "je":[49.214439,-2.13125],
  "jm":[18.109581,-77.297508],
  "jo":[30.585164,36.238414],
  "jp":[36.204824,138.252924],
  "ke":[-0.023559,37.906193],
  "kg":[41.20438,74.766098],
  "kh":[12.565679,104.990963],
  "ki":[-3.370417,-168.734039],
  "km":[-11.875001,43.872219],
  "kn":[17.357822,-62.782998],
  "kp":[40.339852,127.510093],
  "kr":[35.907757,127.766922],
  "kw":[29.31166,47.481766],
  "ky":[19.513469,-80.566956],
  "kz":[48.019573,66.923684],
  "la":[19.85627,102.495496],
  "lb":[33.854721,35.862285],
  "lc":[13.909444,-60.978893],
  "li":[47.166,9.555373],
  "lk":[7.873054,80.771797],
  "lr":[6.428055,-9.429499],
  "ls":[-29.609988,28.233608],
  "lt":[55.169438,23.881275],
  "lu":[49.815273,6.129583],
  "lv":[56.879635,24.603189],
  "ly":[26.3351,17.228331],
  "ma":[31.791702,-7.09262],
  "mc":[43.750298,7.412841],
  "md":[47.411631,28.369885],
  "me":[42.708678,19.37439],
  "mg":[-18.766947,46.869107],
  "mh":[7.131474,171.184478],
  "mk":[41.608635,21.745275],
  "ml":[17.570692,-3.996166],
  "mm":[21.913965,95.956223],
  "mn":[46.862496,103.846656],
  "mo":[22.198745,113.543873],
  "mp":[17.33083,145.38469],
  "mq":[14.641528,-61.024174],
  "mr":[21.00789,-10.940835],
  "ms":[16.742498,-62.187366],
  "mt":[35.937496,14.375416],
  "mu":[-20.348404,57.552152],
  "mv":[3.202778,73.22068],
  "mw":[-13.254308,34.301525],
  "mx":[23.634501,-102.552784],
  "my":[4.210484,101.975766],
  "mz":[-18.665695,35.529562],
  "na":[-22.95764,18.49041],
  "nc":[-20.904305,165.618042],
  "ne":[17.607789,8.081666],
  "nf":[-29.040835,167.954712],
  "ng":[9.081999,8.675277],
  "ni":[12.865416,-85.207229],
  "nl":[52.132633,5.291266],
  "no":[60.472024,8.468946],
  "np":[28.394857,84.124008],
  "nr":[-0.522778,166.931503],
  "nu":[-19.054445,-169.867233],
  "nz":[-40.900557,174.885971],
  "om":[21.512583,55.923255],
  "pa":[8.537981,-80.782127],
  "pe":[-9.189967,-75.015152],
  "pf":[-17.679742,-149.406843],
  "pg":[-6.314993,143.95555],
  "ph":[12.879721,121.774017],
  "pk":[30.375321,69.345116],
  "pl":[51.919438,19.145136],
  "pm":[46.941936,-56.27111],
  "pn":[-24.703615,-127.439308],
  "pr":[18.220833,-66.590149],
  "ps":[31.952162,35.233154],
  "pt":[39.399872,-8.224454],
  "pw":[7.51498,134.58252],
  "py":[-23.442503,-58.443832],
  "qa":[25.354826,51.183884],
  "re":[-21.115141,55.536384],
  "ro":[45.943161,24.96676],
  "rs":[44.016521,21.005859],
  "ru":[61.52401,105.318756],
  "rw":[-1.940278,29.873888],
  "sa":[23.885942,45.079162],
  "sb":[-9.64571,160.156194],
  "sc":[-4.679574,55.491977],
  "sd":[12.862807,30.217636],
  "se":[60.128161,18.643501],
  "sg":[1.352083,103.819836],
  "sh":[-24.143474,-10.030696],
  "si":[46.151241,14.995463],
  "sj":[77.553604,23.670272],
  "sk":[48.669026,19.699024],
  "sl":[8.460555,-11.779889],
  "sm":[43.94236,12.457777],
  "sn":[14.497401,-14.452362],
  "so":[5.152149,46.199616],
  "sr":[3.919305,-56.027783],
  "st":[0.18636,6.613081],
  "sv":[13.794185,-88.89653],
  "sy":[34.802075,38.996815],
  "sz":[-26.522503,31.465866],
  "tc":[21.694025,-71.797928],
  "td":[15.454166,18.732207],
  "tf":[-49.280366,69.348557],
  "tg":[8.619543,0.824782],
  "th":[15.870032,100.992541],
  "tj":[38.861034,71.276093],
  "tk":[-8.967363,-171.855881],
  "tl":[-8.874217,125.727539],
  "tm":[38.969719,59.556278],
  "tn":[33.886917,9.537499],
  "to":[-21.178986,-175.198242],
  "tr":[38.963745,35.243322],
  "tt":[10.691803,-61.222503],
  "tv":[-7.109535,177.64933],
  "tw":[23.69781,120.960515],
  "tz":[-6.369028,34.888822],
  "ua":[48.379433,31.16558],
  "ug":[1.373333,32.290275],
  "us":[37.09024,-95.712891],
  "uy":[-32.522779,-55.765835],
  "uz":[41.377491,64.585262],
  "va":[41.902916,12.453389],
  "vc":[12.984305,-61.287228],
  "ve":[6.42375,-66.58973],
  "vg":[18.420695,-64.639968],
  "vi":[18.335765,-64.896335],
  "vn":[14.058324,108.277199],
  "vu":[-15.376706,166.959158],
  "wf":[-13.768752,-177.156097],
  "ws":[-13.759029,-172.104629],
  "xk":[42.602636,20.902977],
  "ye":[15.552727,48.516388],
  "yt":[-12.8275,45.166244],
  "za":[-30.559482,22.937506],
  "zm":[-13.133897,27.849332],
  "zw":[-19.015438,29.154857]
}

unlikely_mirror_countries = {
  # it's unlikely that there will ever be mirrors from these countries
  # (I'd be happy to be proven wrong, though)
  "ag", # Antigua and Barbuda
  "ai", # Anguilla
  "an", # Netherlands Antilles
  "aq", # Antarctica
  "as", # American Samoa
  "aw", # Aruba
  "bb", # Barbados
  "bm", # Bermuda
  "bv", # Bouvet Island
  "cc", # Cocos [Keeling] Islands
  "ck", # Cook Islands
  "cx", # Christmas Island
  "dm", # Dominica
  "eh", # Western Sahara
  "fk", # Falkland Islands
  "fm", # Micronesia
  "fo", # Faroe Islands
  "gd", # Grenada
  "gg", # Guernsey
  "gi", # Gibraltar
  "gs", # South Georgia and the South Sandwich Islands
  "gu", # Guam
  "gz", # Gaza Strip
  "hm", # Heard Island and McDonald Islands
  "im", # Isle of Man
  "io", # British Indian Ocean Territory
  "ki", # Kiribati
  "kn", # Saint Kitts and Nevis
  "kp", # North Korea
  "ky", # Cayman Islands
  "lc", # Saint Lucia
  "li", # Liechtenstein
  "mh", # Marshall Islands
  "mp", # Northern Mariana Islands
  "mq", # Martinique
  "ms", # Montserrat
  "nf", # Norfolk Island
  "nr", # Nauru
  "nu", # Niue
  "pf", # French Polynesia
  "pm", # Saint Pierre and Miquelon
  "pn", # Pitcairn Islands
  "ps", # Palestinian Territories
  "pw", # Palau
  "sb", # Solomon Islands
  "sh", # Saint Helena
  "sj", # Svalbard and Jan Mayen
  "sm", # San Marino
  "st", # Sao Tome and Principe
  "tc", # Turks and Caicos Islands
  "tf", # French Southern Territories
  "tk", # Tokelau
  "to", # Tonga
  "tv", # Tuvalu
  "va", # Vatican City
  "vc", # Saint Vincent and the Grenadines
  "vg", # British Virgin Islands
  "vi", # U.S. Virgin Islands
  "vu", # Vanuatu
  "wf", # Wallis and Futuna
  "ws", # Samoa
  "yt", # Mayotte
}

remote_countries = {
  # these countries are far away from other countries, need more than a 5000 km range
  "aq", # Antarctica
  "ar", # Argentina
  "as", # American Samoa
  "au", # Australia
  "ck", # Cook Islands
  "fj", # Fiji
  "fk", # Falkland Islands
  "gs", # South Georgia and the South Sandwich Islands
  "hm", # Heard Island and McDonald Islands
  "ki", # Kiribati
  "mh", # Marshall Islands
  "nc", # New Caledonia
  "nf", # Norfolk Island
  "nr", # Nauru
  "nu", # Niue
  "nz", # New Zealand
  "pf", # French Polynesia
  "pn", # Pitcairn Islands
  "sb", # Solomon Islands
  "tf", # French Southern Territories
  "tk", # Tokelau
  "to", # Tonga
  "tv", # Tuvalu
  "vu", # Vanuatu
  "wf", # Wallis and Futuna
  "ws", # Samoa
}

def distance_between_two_countries(cc1, cc2):
  return distance_between_two_points(coords[cc1][0], coords[cc1][1], coords[cc2][0], coords[cc2][1])

def distance_between_two_points(lat1, lon1, lat2, lon2):
  return int(6371 * acos(sin(radians(lat1))*sin(radians(lat2)) + \
    cos(radians(lat1))*cos(radians(lat2))*cos(radians(lon1)-radians(lon2))))

results = []
for cc1 in coords:
  distances = []
  for cc2 in coords:
    if cc1 <> cc2 and cc2 not in unlikely_mirror_countries:
      distances.append([cc2, distance_between_two_countries(cc1, cc2)])

  additions = []
  sortedlist = sorted(distances, key=lambda x: x[1])
  for cc in sortedlist:
    if cc[1] > 0 and (cc[1] <= 5000 or (cc1 in remote_countries and cc[1] <= 8000)) \
    and (not ccgroups.has_key(cc1) or cc[0] not in ccgroups[cc1]):
      additions.append(cc[0])
  results.append("\"" + cc1 + "\":[\"" + "\",\"".join(additions) + "\"]")

print "{\n" + ",\n".join(sorted(results)) + "\n}"

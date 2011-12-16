#!/bin/sh
# UTF-8
##############################################################################
# Shibboleth deployment script by Anders Lördal                              #
# Högskolan i Gävle and SWAMID                                               #
#                                                                            #
# Version 1.1                                                                #
#                                                                            #
# Deploys a working IDP for SWAMID on an Ubuntu system                       #
# Uses: jboss-as-distribution-6.1.0.Final or tomcat6                         #
#       shibboleth-identityprovider-2.3.5                                    #
#       cas-client-3.2.1-release                                             #
#                                                                            #
# Templates are provided for CAS and LDAP authentication                     #
#                                                                            #
# To add a new template for another authentication, just add a new directory #
# under the "prep" directory, add the neccesary .diff files and add any      #
# special hanling of those files to the script.                              #
#                                                                            #
# You can pre-set configuration values in the file "config"                  #
#                                                                            #
# Please send questions and improvements to: anders.lordal@hig.se            #
##############################################################################

# Set cleanUp to 0 (zero) for debugging of created files
cleanUp=1
upgrade=0
files=""
messages=""
shibVer="2.3.5"
certpath="/opt/shibboleth-idp/ssl/"
httpsP12="/opt/shibboleth-idp/credentials/https.p12"
certREQ="${certpath}tomcat.req"

if [ "$USERNAME" != "root" ]
then
	echo "Run as root!"
	exit
fi

# set JAVA_HOME, script path and check for upgrade
if [ -z "$JAVA_HOME" ]
then
	export JAVA_HOME=/usr/lib/jvm/java-6-openjdk/jre/
	if [ -z "`grep 'JAVA_HOME' /root/.bashrc`" ]
	then
		echo "export JAVA_HOME=/usr/lib/jvm/java-6-openjdk/jre/" >> /root/.bashrc
	fi
fi
ts=`date "+%s"`
javaCAcerts="${JAVA_HOME}/lib/security/cacerts"
Spath="$(cd "$(dirname "$0")" && pwd)"
if [ -L "/opt/shibboleth-identityprovider" -a -d "/opt/shibboleth-idp" ]
then
	upgrade=1
fi

if [ -f "${Spath}/config" ]
then
	. ${Spath}/config
fi

if [ "$upgrade" -eq 0 ]
then
	if [ -z "$appserv" ]
	then
		echo "Application server [ tomcat | jboss ]"
		read appserv
		echo ""
	fi

	if [ -z "$type" ]
	then
		echo "Authentication [ `ls ${Spath}/prep |grep -v common | perl -npe 's/\n/\ /g'`]"
		read type
		echo ""
	fi
	prep="prep/$type"

	if [ -z "$google" ]
	then
		echo "Release attributes to Google? [Y/n]: (Swamid, Swamid-test and testshib.org installed as standard)"
		read google
		echo ""
	fi

	if [ "$google" != "n" -a -z "$googleDom" ]
	then
		echo "Your Google domain name: (student.xxx.yy)"
		read googleDom
		echo ""
	fi

	if [ -z "$ntpserver" ]
	then
		echo "Specify NTP server:"
		read ntpserver
		echo ""
	fi

	if [ -z "$ldapserver" ]
	then
		echo "Specify LDAP URL: (ldap.xxx.yy) (seperate servers with space)"
		read ldapserver
		echo ""
	fi

	if [ -z "$ldapbasedn" ]
	then
		echo "Specify LDAP Base DN:"
		read ldapbasedn
		echo ""
	fi

	if [ -z "$ldapbinddn" ]
	then
		echo "Specify LDAP Bind DN:"
		read ldapbinddn
		echo ""
	fi

	if [ -z "$ldappass" ]
	then
		echo "Specify LDAP Password:"
		read ldappass
		echo ""
	fi

	if [ "$type" = "ldap" -a -z "$subsearch" ]
	then
		echo "LDAP Subsearch: [ true | false ]"
		read subsearch
		echo ""
	fi

	if [ -z "$idpurl" ]
	then
		echo "Specify IDP URL: (https://idp.xxx.yy)"
		read idpurl
		echo ""
	fi

	if [ "$type" = "cas" ]
	then
		if [ -z "$caslogurl" ]
		then
			echo "Specify CAS Login URL server: (https://cas.xxx.yy/cas/login)"
			read caslogurl
			echo ""
		fi

		if [ -z "$casurl" ]
		then
			echo "Specify CAS URL server: (https://cas.xxx.yy/cas)"
			read casurl
			echo ""
		fi
	fi

	if [ -z "$certOrg" ]
	then
		echo "Organisation name string for certificate request:"
		read certOrg
		echo ""
	fi

	if [ -z "$certC" ]
	then
		echo "Country string for certificate request: (empty string for 'SE')"
		read certC
		echo ""
	fi
	if [ -z "$certC" ]
	then
		certC="SE"
	fi

	if [ -z "$fticks" ]
	then
		echo "Send anonymous usage data to SWAMID [ y | n ]?"
		read fticks
		echo ""
	fi
	if [ -z "$selfsigned" ]
	then
		echo "Create a self signed certificate for https [ y | n ]"
		read selfsigned
		echo ""
	fi

	echo "IDP keystore password (empty string generates new password)"
	read pass
	echo ""
	echo "Keystore password for https (empty string generates new password)"
	read httpspass
fi



/bin/echo -e "\n\n\n"
echo "Starting deployment!"
if [ "$upgrade" -eq 1 ]
then
	echo "Previous installation found, performing upgrade."

	apt-get -qq install unzip wget
	cd /opt
	currentShib=`ls -l /opt/shibboleth-identityprovider |awk '{print $NF}'`
	currentVer=`echo $currentShib |awk -F\- '{print $NF}'`
	if [ "$currentVer" = "$shibVer" ]
	then
		mv $currentShib ${currentShib}.$ts
	fi

	if [ ! -f "${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip" ]
	then
		echo "Shibboleth not found, fetching from web"
		wget -q -O ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip http://www.shibboleth.net/downloads/identity-provider/${shibVer}/shibboleth-identityprovider-${shibVer}-bin.zip
	fi
	unzip -q ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip
	chmod -R 755 /opt/shibboleth-identityprovider-${shibVer}

	unlink /opt/shibboleth-identityprovider
	ln -s /opt/shibboleth-identityprovider-${shibVer} /opt/shibboleth-identityprovider

	if [ -d "/opt/cas-client-3.2.1" ]
	then
		if [ -z "$idpurl" ]
		then
			echo "Specify IDP URL: (https://idp.xxx.yy)"
			read idpurl
			echo ""
		fi
		if [ -z "$caslogurl" ]
		then
			echo "Specify CAS Login URL server: (https://cas.xxx.yy/cas/login)"
			read caslogurl
			echo ""
		fi

		if [ -z "$casurl" ]
		then
			echo "Specify CAS URL server: (https://cas.xxx.yy/cas)"
			read casurl
			echo ""
		fi

		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/lib/
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/lib/
		mkdir /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib

		cat ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff.template \
			| perl -npe "s#IdPuRl#$idpurl#" \
			| perl -npe "s#CaSuRl#$caslogurl#" \
			| perl -npe "s#CaS2uRl#$casurl#" \
			> ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
		files="`echo $files` ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff"

		patch /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/web.xml -i ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
	fi

	if [ -d "/opt/ndn-shib-fticks" ]
	then
		cp /opt/ndn-shib-fticks/target/*.jar /opt/shibboleth-identityprovider/lib
	else
		echo "Send anonymous usage data to SWAMID [ y | n ]?"
		read fticks
		echo ""

		if [ "$fticks" != "n" ]
		then
			echo "Installing ndn-shib-fticks"
			apt-get install git maven2
			cd /opt
			git clone git://github.com/leifj/ndn-shib-fticks.git
			cd ndn-shib-fticks
			mvn
			cp /opt/ndn-shib-fticks/target/*.jar /opt/shibboleth-identityprovider/lib
		fi
	fi

	cd /opt
	tar zcf /opt/backup-shibboleth-idp.${ts}.tar.gz shibboleth-idp

	cd /opt/shibboleth-identityprovider
	/bin/echo -e "\n\n\n\n"
	sh install.sh -Dinstall.config=no -Didp.home.input="/opt/shibboleth-idp"

else

	# install depends
	echo "Updating apt and installing dependancies"
	apt-get -qq update
	apt-get -qq install unzip default-jre apg wget

	# generate keystore pass
	if [ -z "$pass" ]
	then
		pass=`apg -m20 -E '"!#<>\' -n 1 -a 0`
	fi
	if [ -z "$httpspass" ]
	then
		httpspass=`apg -m20 -E '"!#<>\' -n 1 -a 0`
	fi
	idpfqdn=`echo $idpurl | awk -F\/ '{print $3}'`

	# get depens if needed
	if [ "$appserv" = "jboss" ]
	then
		if [ ! -f "${Spath}/files/jboss-as-distribution-6.1.0.Final.zip" ]
		then
			echo "Jboss not found, fetching from web"
			wget -q -O ${Spath}/files/jboss-as-distribution-6.1.0.Final.zip http://download.jboss.org/jbossas/6.1/jboss-as-distribution-6.1.0.Final.zip
		fi
	fi

	if [ "$appserv" = "tomcat" ]
	then
		test=`dpkg -s tomcat6 > /dev/null 2>&1`
		isInstalled=$?
		if [ "$isInstalled" -ne 0 ]
		then
			apt-get -qq install tomcat6
		fi
	fi

	if [ ! -f "${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip" ]
	then
		echo "Shibboleth not found, fetching from web"
		wget -q -O ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip http://www.shibboleth.net/downloads/identity-provider/${shibVer}/shibboleth-identityprovider-${shibVer}-bin.zip
	fi

	if [ "$type" = "cas" ]
	then
		if [ ! -f "${Spath}/files/cas-client-3.2.1-release.zip" ]
		then
			echo "Cas-client not found, fetching from web"
			wget -q -O ${Spath}/files/cas-client-3.2.1-release.zip http://downloads.jasig.org/cas-clients/cas-client-3.2.1-release.zip
		fi
	fi

	# unzip all files
	cd /opt
	echo "Unzipping dependancies"
	if [ "$appserv" = "jboss" ]
	then
		unzip -q ${Spath}/files/jboss-as-distribution-6.1.0.Final.zip
		chmod 755 jboss-6.1.0.Final
		ln -s /opt/jboss-6.1.0.Final /opt/jboss
	fi

	unzip -q ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip
	chmod -R 755 /opt/shibboleth-identityprovider-${shibVer}

	if [ "$type" = "cas" ]
	then
		unzip -q ${Spath}/files/cas-client-3.2.1-release.zip
	fi

	chmod 755 shibboleth-identityprovider-${shibVer}
	ln -s shibboleth-identityprovider-${shibVer} shibboleth-identityprovider

	if [ "$type" = "cas" ]
	then
	# copy cas depends into shibboleth
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/lib/
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/lib/
		mkdir /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib

		cat ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff.template \
			| perl -npe "s#IdPuRl#$idpurl#" \
			| perl -npe "s#CaSuRl#$caslogurl#" \
			| perl -npe "s#CaS2uRl#$casurl#" \
			> ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
		files="`echo $files` ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff"

		patch /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/web.xml -i ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
	fi

	if [ "$fticks" != "n" ]
	then
		echo "Installing ndn-shib-fticks"
		apt-get install git maven2
		cd /opt
		git clone git://github.com/leifj/ndn-shib-fticks.git
		cd ndn-shib-fticks
		mvn
		cp /opt/ndn-shib-fticks/target/*.jar /opt/shibboleth-identityprovider/lib
	fi

	# run shibboleth installer
	cd /opt/shibboleth-identityprovider
	/bin/echo -e "\n\n\n"
	sh install.sh -Didp.home.input="/opt/shibboleth-idp" -Didp.hostname.input="${idpfqdn}" -Didp.keystore.pass="${pass}"


	# prepare config from templates
	cat ${Spath}/xml/server.xml.${appserv} \
		| perl -npe "s#ShIbBKeyPaSs#${pass}#" \
		| perl -npe "s#HtTpSkEyPaSs#${httpspass}#" \
		| perl -npe "s#HtTpSJkS#${httpsP12}#" \
		| perl -npe "s#TrUsTsToRe#${javaCAcerts}#" \
		> ${Spath}/xml/server.xml
	files="`echo $files` ${Spath}/xml/server.xml"

	ldapServerStr=""
	for i in `echo $ldapserver`
	do
		ldapServerStr="`echo $ldapServerStr` ldap://$i"
	done
	ldapServerStr=`echo $ldapServerStr | perl -npe 's/^\s+//'`
	cat ${Spath}/xml/attribute-resolver.xml.diff.template \
		| perl -npe "s#LdApUrI#$ldapServerStr#" \
		| perl -npe "s/LdApBaSeDn/$ldapbasedn/" \
		| perl -npe "s/LdApCrEdS/$ldapbinddn/" \
		| perl -npe "s/LdApPaSsWoRd/$ldappass/" \
		> ${Spath}/xml/attribute-resolver.xml.diff
	files="`echo $files` ${Spath}/xml/attribute-resolver.xml.diff"

	# Get TCS CA chain, import ca-certs into java and create https cert request
	mkdir -p ${certpath}
	cd ${certpath}
	echo "Fetching TCS CA chain from web"
	wget -q -O ${certpath}server.chain http://webkonto.hig.se/chain.pem

	echo "Installing TCS CA chain in java cacert keystore"
	cnt=1
	for i in `cat ${certpath}server.chain | perl -npe 's/\ /\*\*\*/g'`
	do
		n=`echo $i | perl -npe 's/\*\*\*/\ /g'`
		echo $n >> ${certpath}${cnt}.root
		ltest=`echo $n | grep "END CERTIFICATE"`
		if [ ! -z "$ltest" ]
		then
			cnt=`expr $cnt + 1`
		fi
	done
	ccnt=1
	while [ $ccnt -lt $cnt ]
	do
		subject=`openssl x509 -noout -in ${certpath}$ccnt.root -subject | awk -F/ '{print $NF}' |cut -d= -f2`
		test=`keytool -list -keystore ${javaCAcerts} -storepass changeit -alias "$subject"`
		res=$?
		if [ $res -ne 0 ]
		then
			keytool -import -trustcacerts -alias "$subject" -file ${certpath}${ccnt}.root -keystore ${javaCAcerts} -storepass changeit 2>/dev/null
		fi
		files="`echo $files` ${certpath}${ccnt}.root"
		ccnt=`expr $ccnt + 1`
	done

	if [ ! -s "${httpsP12}" ]
	then
		echo "Generating SSL key and certificate request"
		openssl genrsa -out ${certpath}server.key 2048 2>/dev/null
		openssl req -new -key ${certpath}server.key -out $certREQ -config ${Spath}/files/openssl.cnf -subj "/CN=${idpfqdn}/O=${certOrg}/C=${certC}"
	fi
	if [ "$selfsigned" = "n" ]
	then
		messages="`/bin/echo -e $messages`\nPut the certificate from TCS in the file: ${certpath}server.crt"
		messages="`/bin/echo -e $messages`\nRun: openssl pkcs12 -export -in ${certpath}server.crt -inkey ${certpath}server.key -out ${httpsP12} -name tomcat -passout pass:${httpspass}"
	else
		openssl x509 -req -days 365 -in $certREQ -signkey ${certpath}server.key -out ${certpath}server.crt
		openssl pkcs12 -export -in ${certpath}server.crt -inkey ${certpath}server.key -out ${httpsP12} -name tomcat -passout pass:${httpspass}
	fi

	# application server specific
	if [ "$appserv" = "jboss" ]
	then
		if [ "$type" = "ldap" ]
		then
			ldapServerStr=""
			for i in `echo $ldapserver`
			do
				ldapServerStr="`echo $ldapServerStr` ldap://$i"
			done
			ldapServerStr=`echo $ldapServerStr | perl -npe 's/^\s+//'`

			cat ${Spath}/${prep}/login-config.xml.diff.template \
				| perl -npe "s#LdApUrI#$ldapServerStr#" \
				| perl -npe "s/LdApBaSeDn/$ldapbasedn/" \
				| perl -npe "s/SuBsEaRcH/$subsearch/" \
				> ${Spath}/${prep}/login-config.xml.diff
			files="`echo $files` ${Spath}/${prep}/login-config.xml.diff"
			patch /opt/jboss/server/default/conf/login-config.xml -i ${Spath}/${prep}/login-config.xml.diff
		fi

		ln -s /opt/shibboleth-idp/war/idp.war /opt/jboss/server/default/deploy/

		cp ${Spath}/xml/server.xml /opt/jboss/server/default/deploy/jbossweb.sar/server.xml
		chmod o-rwx /opt/jboss/server/default/deploy/jbossweb.sar/server.xml

		echo "Add basic jboss init script to start on boot"
		cp ${Spath}/files/jboss /etc/init.d/
		update-rc.d jboss defaults
	fi

	if [ "$appserv" = "tomcat" ]
	then
		if [ "$type" = "ldap" ]
		then
			ldapServerStr=""
			for i in `echo $ldapserver`
			do
				ldapServerStr="`echo $ldapServerStr` ldap://${i}:389"
			done

			cat ${Spath}/${prep}/login.conf.diff.template \
				| perl -npe "s#LdApUrI#$ldapServerStr#" \
				| perl -npe "s/LdApBaSeDn/$ldapbasedn/" \
				> ${Spath}/${prep}/login.conf.diff
			files="`echo $files` ${Spath}/${prep}/login.conf.diff"
			patch /opt/shibboleth-idp/conf/login.config -i ${Spath}/${prep}/login.conf.diff
		fi

		cp ${Spath}/xml/tomcat.idp.xml /var/lib/tomcat6/conf/Catalina/localhost/idp.xml

		if [ ! -d "/usr/share/tomcat6/endorsed" ]
		then
			mkdir /usr/share/tomcat6/endorsed
			cp /opt/shibboleth-identityprovider/endorsed/* /usr/share/tomcat6/endorsed
		fi

		. /etc/default/tomcat6
		if [ -z "`echo $JAVA_OPTS | grep '/usr/share/tomcat6/endorsed'`" ]
		then
			JAVA_OPTS="$JAVA_OPTS -Djava.endorsed.dirs=/usr/share/tomcat6/endorsed"
			echo "JAVA_OPTS=\"$JAVA_OPTS\"" >> /etc/default/tomcat6
			echo "AUTHBIND=yes" >> /etc/default/tomcat6
		else
			messages="`/bin/echo -e $messages`\nJAVA_OPTS for tomcat already configured"
		fi
		if [ "${AUTHBIND}" != "yes" ]
		then
			echo "AUTHBIND=yes" >> /etc/default/tomcat6
		else
			messages="`/bin/echo -e $messages`\nAUTHBIND for tomcat already configured"
		fi

		wget -q -O /usr/share/tomcat6/lib/tomcat6-dta-ssl-1.0.0.jar http://shibboleth.internet2.edu/downloads/maven2/edu/internet2/middleware/security/tomcat6/tomcat6-dta-ssl/1.0.0/tomcat6-dta-ssl-1.0.0.jar

		cp /etc/tomcat6/server.xml /etc/tomcat6/server.xml.${ts}
		cp ${Spath}/xml/server.xml /etc/tomcat6/server.xml
		chmod o-rwx /etc/tomcat6/server.xml

		if [ -d "/var/lib/tomcat6/webapps/ROOT" ]
		then
			mv /var/lib/tomcat6/webapps/ROOT /opt/disabled.tomcat6.webapps.ROOT
		fi

		chown tomcat6 /opt/shibboleth-idp/metadata
		chown -R tomcat6 /opt/shibboleth-idp/logs/

		cp /usr/share/tomcat6/lib/servlet-api.jar /opt/shibboleth-idp/lib/
	fi

	cp ${Spath}/files/md-signer.crt /opt/shibboleth-idp/credentials

	# patch shibboleth config files
	echo "Patching config files"
	patch /opt/shibboleth-idp/conf/handler.xml -i ${Spath}/${prep}/handler.xml.diff
	patch /opt/shibboleth-idp/conf/relying-party.xml -i ${Spath}/xml/relying-party.xml.diff
	patch /opt/shibboleth-idp/conf/attribute-filter.xml -i ${Spath}/xml/attribute-filter.xml.diff
	patch /opt/shibboleth-idp/conf/attribute-resolver.xml -i ${Spath}/xml/attribute-resolver.xml.diff

	if [ "$google" != "n" ]
	then
		patch /opt/shibboleth-idp/conf/attribute-filter.xml -i ${Spath}/xml/google-filter.diff
		patch /opt/shibboleth-idp/conf/attribute-resolver.xml -i ${Spath}/xml/google-resolver.diff
		cat ${Spath}/xml/google-relay.diff.template | perl -npe "s/IdPfQdN/$idpfqdn/" > ${Spath}/xml/google-relay.diff
		files="`echo $files` ${Spath}/xml/google-relay.diff"
		patch /opt/shibboleth-idp/conf/relying-party.xml -i ${Spath}/xml/google-relay.diff
		cat ${Spath}/xml/google.xml | perl -npe "s/GoOgLeDoMaIn/$googleDom/" > /opt/shibboleth-idp/metadata/google.xml
	fi

	if [ "$fticks" != "n" ]
	then
		patch /opt/shibboleth-idp/conf/logging.xml -i ${Spath}/xml/fticks.diff
		touch /opt/shibboleth-idp/conf/fticks-key.txt
		if [ "$appserv" = "tomcat" ]
		then
			chown tomcat6 /opt/shibboleth-idp/conf/fticks-key.txt
		fi
	fi


	# add crontab entry for ntpdate
	test=`crontab -l |grep "$ntpserver" |grep ntpdate`
	if [ -z "$test" ]
	then
		echo "Adding crontab entry for ntpdate"
		CRONTAB=`crontab -l | perl -npe 's/^$//'`
		if [ ! -z "$CRONTAB" ]
		then
			CRONTAB="${CRONTAB}\n"
		fi
		/bin/echo -e "${CRONTAB}*/5 *  *   *   *     /usr/sbin/ntpdate $ntpserver > /dev/null 2>&1" | crontab
	fi
fi

if [ $cleanUp -eq 1 ]
then
	# remove configs with templates
	for i in $files
	do
		rm $i
	done
else
	echo "Files created by script"
	for i in $files
	do
		echo $i
	done
fi

/bin/echo -e "\n\n\n"

if [ "$upgrade" -eq 1 ]
then
	echo "Upgrade done."
	echo "A backup of the previos shibboleth installation is saved in: /opt/backup-shibboleth-idp.${ts}.tar.gz"
else
	if [ "$selfsigned" = "n" ]
	then
		cat $certREQ
		echo "Here is the certificate request, go get at cert!"
		echo "Or replace the cert files in ${certpath}"
		/bin/echo -e "\n\nNOTE!!! the keystore for https is a PKCS12 store\n\n"
	fi
	echo ""
	echo "Register at testshib.org and register idp, and run a logon test."
	echo "Certificate for testshib is in the file: /opt/shibboleth-idp/credentials/idp.crt"
fi

if [ "$type" = "ldap" ]
then
	/bin/echo -e "\n\n"
	echo "Read this to customize the logon page: https://wiki.shibboleth.net/confluence/display/SHIB2/IdPAuthUserPassLoginPage"
fi

if [ ! -z "$messages" ]
then
	/bin/echo -e $messages
fi
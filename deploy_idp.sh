#!/bin/sh
# UTF-8
##############################################################################
# Shibboleth deployment script by Anders Lördal                              #
# Högskolan i Gävle and SWAMID                                               #
#                                                                            #
# Version 1.4                                                                #
#                                                                            #
# Deploys a working IDP for SWAMID on an Ubuntu system                       #
# Uses: jboss-as-distribution-6.1.0.Final or tomcat6                         #
#       shibboleth-identityprovider-2.3.5                                    #
#       cas-client-3.2.1-release                                             #
#       mysql-connector-java-5.1.18 (for EPTID)                              #
#                                                                            #
# Templates are provided for CAS and LDAP authentication                     #
#                                                                            #
# To disable the whiptail gui run with argument "-cli"                       #
#                                                                            #
# To add a new template for another authentication, just add a new directory #
# under the "prep" directory, add the neccesary .diff files and add any      #
# special hanling of those files to the script.                              #
#                                                                            #
# You can pre-set configuration values in the file "config"                  #
#                                                                            #
# Please send questions and improvements to: anders.lordal@hig.se            #
##############################################################################
mdSignerFinger="12:60:D7:09:6A:D9:C1:43:AD:31:88:14:3C:A8:C4:B7:33:8A:4F:CB"

# Set cleanUp to 0 (zero) for debugging of created files
cleanUp=1
# Default enable of whiptail UI
sUI=y

upgrade=0
files=""
shibVer="2.3.5"
whipSize="13 75"
certpath="/opt/shibboleth-idp/ssl/"
httpsP12="/opt/shibboleth-idp/credentials/https.p12"
certREQ="${certpath}tomcat.req"
Dname=`hostname`
Dname=`host -t A ${Dname} | awk '{print $1}' | cut -d\. -f2-`
apgCmd="apg -m20 -E '\"!#<>/\' -n 1 -a 0"
bupFile="/opt/backup-shibboleth-idp.${ts}.tar.gz"
idpPath="/opt/shibboleth-idp/"
certificateChain="http://webkonto.hig.se/chain.pem"
tomcatDepend="http://shibboleth.internet2.edu/downloads/maven2/edu/internet2/middleware/security/tomcat6/tomcat6-dta-ssl/1.0.0/tomcat6-dta-ssl-1.0.0.jar"

if [ "${USERNAME}" != "root" ]
then
	echo "Run as root!"
	exit
fi

cleanBadInstall() {
	if [ -d "/opt/shibboleth-identityprovider" ]
	then
		rm -rf /opt/shibboleth-identityprovider*
	fi
	if [ -L "/opt/jboss" ]
	then
		rm -rf /opt/jboss*
	fi
	if [ -d "/opt/cas-client-3.2.1" ]
	then
		rm -rf /opt/cas-client-3.2.1
	fi
	if [ -d "/opt/ndn-shib-fticks" ]
	then
		rm -rf /opt/ndn-shib-fticks
	fi
	if [ -d "/opt/shibboleth-idp" ]
	then
		rm -rf /opt/shibboleth-idp
	fi
}



# set JAVA_HOME, script path and check for upgrade
if [ -z "${JAVA_HOME}" ]
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
messages="${Spath}/msg.txt"

if [ -L "/opt/shibboleth-identityprovider" -a -d "/opt/shibboleth-idp" ]
then
	upgrade=1
fi

if [ ! -x "/usr/bin/whiptail" ]
then
	sUI="n"
fi
if [ "$1" = "-cli" ]
then
	sUI="n"
fi

if [ -f "${Spath}/config" ]
then
	. ${Spath}/config
fi

if [ "${upgrade}" -eq 0 ]
then
	if [ -z "${appserv}" ]
	then
		if [ "$sUI" = "y" ]
		then
			appserv=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Application server" --nocancel --menu --clear  -- "Which application server do you want to use?" ${whipSize} 2 \
				tomcat "Apache Tomcat 6" jboss "Jboss Application server 6" 3>&1 1>&2 2>&3)
		else
			echo "Application server [ tomcat | jboss ]"
			read appserv
			echo ""
		fi
	fi

	if [ -z "${type}" ]
	then
		if [ "$sUI" = "y" ]
		then
			tList="whiptail --backtitle \"SWAMID IDP Deployer\" --title \"Authentication type\" --nocancel --menu --clear -- \"Which authentication type do you want to use?\" ${whipSize} 2"
			for i in `ls ${Spath}/prep | perl -npe 's/\n/\ /g'`
			do
				tDesc=`cat ${Spath}/prep/${i}/.desc`
				tList="`echo ${tList}` \"${i}\" \"${tDesc}\""
			done
			type=$(eval "${tList} 3>&1 1>&2 2>&3")
		else
			echo "Authentication [ `ls ${Spath}/prep |grep -v common | perl -npe 's/\n/\ /g'`]"
			read type
			echo ""
		fi
	fi
	prep="prep/${type}"

	if [ -z "${google}" ]
	then
		if [ "$sUI" = "y" ]
		then
			whiptail --backtitle "SWAMID IDP Deployer" --title "Attributes to Google" --yesno --clear -- \
				"Do you want to release attributes to google?\n\nSwamid, Swamid-test and testshib.org installed as standard" ${whipSize} 3>&1 1>&2 2>&3
			googleNum=$?
			google="n"
			if [ "${googleNum}" -eq 0 ]
			then
				google="y"
			fi
		else
			echo "Release attributes to Google? [Y/n]: (Swamid, Swamid-test and testshib.org installed as standard)"
			read google
			echo ""
		fi
	fi

	while [ "${google}" != "n" -a -z "${googleDom}" ]
	do
		if [ "$sUI" = "y" ]
		then
			googleDom=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Your Google domain name" --nocancel --inputbox --clear -- \
				"Please input your Google domain name (student.xxx.yy)." ${whipSize} "student.${Dname}" 3>&1 1>&2 2>&3)
		else
			echo "Your Google domain name: (student.xxx.yy)"
			read googleDom
			echo ""
		fi
	done

	while [ -z "${ntpserver}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ntpserver=$(whiptail --backtitle "SWAMID IDP Deployer" --title "NTP server" --nocancel --inputbox --clear -- \
				"Please input your NTP server address." ${whipSize} "ntp.${Dname}" 3>&1 1>&2 2>&3)
		else
			echo "Specify NTP server:"
			read ntpserver
			echo ""
		fi
		/usr/sbin/ntpdate ${ntpserver} > /dev/null 2>&1
	done

	while [ -z "${ldapserver}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ldapserver=$(whiptail --backtitle "SWAMID IDP Deployer" --title "LDAP server" --nocancel --inputbox --clear -- \
				"Please input yout LDAP server(s) (ldap.xxx.yy).\n\nSeparate multiple servers with spaces." ${whipSize} "ldap.${Dname}" 3>&1 1>&2 2>&3)
		else
			echo "Specify LDAP URL: (ldap.xxx.yy) (seperate servers with space)"
			read ldapserver
			echo ""
		fi
	done

	while [ -z "${ldapbasedn}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ldapbasedn=$(whiptail --backtitle "SWAMID IDP Deployer" --title "LDAP Base DN" --nocancel --inputbox --clear -- \
				"Please input your LDAP Base DN" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Specify LDAP Base DN:"
			read ldapbasedn
			echo ""
		fi
	done

	while [ -z "${ldapbinddn}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ldapbinddn=$(whiptail --backtitle "SWAMID IDP Deployer" --title "LDAP Bind DN" --nocancel --inputbox --clear -- \
				"Please input your LDAP Bind DN" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Specify LDAP Bind DN:"
			read ldapbinddn
			echo ""
		fi
	done

	while [ -z "${ldappass}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ldappass=$(whiptail --backtitle "SWAMID IDP Deployer" --title "LDAP Password" --nocancel --passwordbox --clear -- \
				"Please input your LDAP Password:" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Specify LDAP Password:"
			read ldappass
			echo ""
		fi
	done

	while [ "${type}" = "ldap" -a -z "${subsearch}" ]
	do
		if [ "$sUI" = "y" ]
		then
			whiptail --backtitle "SWAMID IDP Deployer" --title "LDAP Subsearch" --nocancel --yesno --clear -- \
				"Do you want to enable LDAP subtree search?" ${whipSize} 3>&1 1>&2 2>&3
			subsearchNum=$?
			subsearch="false"
			if [ "${subsearchNum}" -eq 0 ]
			then
				subsearch="true"
			fi
		else
			echo "LDAP Subsearch: [ true | false ]"
			read subsearch
			echo ""
		fi
	done

	while [ -z "${ninc}" ]
	do
		if [ "$sUI" = "y" ]
		then
			ninc=$(whiptail --backtitle "SWAMID IDP Deployer" --title "norEduPersonNIN" --nocancel --inputbox --clear -- \
				"Please specify LDAP attribute for norEduPersonNIN (YYYYMMDDnnnn)." ${whipSize} "norEduPersonNIN" 3>&1 1>&2 2>&3)
		else
			echo "LDAP attribute for norEduPersonNIN (YYYYMMDDnnnn)? (empty string for 'norEduPersonNIN')"
			read ninc
			echo ""
			if [ -z "${ninc}" ]
			then
				ninc="norEduPersonNIN"
			fi
		fi
	done

	while [ -z "${idpurl}" ]
	do
		if [ "$sUI" = "y" ]
		then
			hostname=`hostname`
			hostname=`host -t A ${hostname} | awk '{print $1}'`
			idpurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "IDP URL" --nocancel --inputbox --clear -- \
				"Please input the URL to this IDP (https://idp.xxx.yy)." ${whipSize} "https://${hostname}" 3>&1 1>&2 2>&3)
		else
			echo "Specify IDP URL: (https://idp.xxx.yy)"
			read idpurl
			echo ""
		fi
	done

	if [ "${type}" = "cas" ]
	then
		while [ -z "${casurl}" ]
		do
			if [ "$sUI" = "y" ]
			then
				casurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "" --nocancel --inputbox --clear -- \
					"Please input the URL to yourCAS server (https://cas.xxx.yy/cas)." ${whipSize} "https://cas.${Dname}/cas" 3>&1 1>&2 2>&3)
			else
				echo "Specify CAS URL server: (https://cas.xxx.yy/cas)"
				read casurl
				echo ""
			fi
		done

		while [ -z "${caslogurl}" ]
		do
			if [ "$sUI" = "y" ]
			then
				caslogurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "" --nocancel --inputbox --clear -- \
					"Please input the Login URL to your CAS server (https://cas.xxx.yy/cas/login)." ${whipSize} "${casurl}/login" 3>&1 1>&2 2>&3)
			else
				echo "Specify CAS Login URL server: (https://cas.xxx.yy/cas/login)"
				read caslogurl
				echo ""
			fi
		done
	fi

	while [ -z "${certOrg}" ]
	do
		if [ "$sUI" = "y" ]
		then
			certOrg=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Certificate organisation" --nocancel --inputbox --clear -- \
				"Please input organisation name string for certificate request" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Organisation name string for certificate request:"
			read certOrg
			echo ""
		fi
	done

	while [ -z "${certC}" ]
	do
		if [ "$sUI" = "y" ]
		then
			certC=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Certificate country" --nocancel --inputbox --clear -- \
				"Please input country string for certificate request." ${whipSize} 'SE' 3>&1 1>&2 2>&3)
		else
			echo "Country string for certificate request: (empty string for 'SE')"
			read certC
			echo ""
			if [ -z "${certC}" ]
			then
				certC="SE"
			fi
		fi
	done

	while [ -z "${certAcro}" ]
	do
		if [ "$sUI" = "y" ]
		then
			certAcro=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Organisation acronym" --nocancel --inputbox --clear -- \
				"Please input organisation Acronym (eg. 'HiG')" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "norEduOrgAcronym: (eg. 'HiG')"
			read certAcro
			echo ""
		fi
	done

	while [ -z "${certLongC}" ]
	do
		if [ "$sUI" = "y" ]
		then
			certLongC=$(whiptail --backtitle "SWAMID IDP Deployer" --title "Country descriptor" --nocancel --inputbox --clear -- \
				"Please input country descriptor (eg. 'Sweden')" ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Country descriptor (eg. 'Sweden')"
			read certLongC
			echo ""
		fi
	done

	if [ -z "${fticks}" ]
	then
		if [ "$sUI" = "y" ]
		then
			whiptail --backtitle "SWAMID IDP Deployer" --title "Send anonymous data" --yesno --clear -- \
				"Do you want to send anonymous usage data to SWAMID?\nThis is recommended." ${whipSize} 3>&1 1>&2 2>&3
			fticsNum=$?
			fticks="n"
			if [ "${fticsNum}" -eq 0 ]
			then
				fticks="y"
			fi
		else
			echo "Send anonymous usage data to SWAMID [ y | n ]?"
			read fticks
			echo ""
		fi
	fi

	if [ -z "${eptid}" ]
	then
		if [ "$sUI" = "y" ]
		then
			whiptail --backtitle "SWAMID IDP Deployer" --title "EPTID" --yesno --clear -- \
				"Do you want to install support for EPTID?\nThis is recommended." ${whipSize} 3>&1 1>&2 2>&3
			eptidNum=$?
			eptid="n"
			if [ "${eptidNum}" -eq 0 ]
			then
				eptid="y"
			fi
		else
			echo "Install support for EPTID [ y | n ]"
			read eptid
			echo ""
		fi
	fi

	if [ "${eptid}" != "n" ]
	then
		if [ "$sUI" = "y" ]
		then
			mysqlPass=$(whiptail --backtitle "SWAMID IDP Deployer" --title "MySQL password" --nocancel --passwordbox --clear -- \
				"Please input the root password for MySQL\n\nEmpty string generates new password." ${whipSize} 3>&1 1>&2 2>&3)
		else
			echo "Root password for MySQL (empty string generates new password)?"
			read mysqlPass
			echo ""
		fi
	fi

	if [ -z "${selfsigned}" ]
	then
		if [ "$sUI" = "y" ]
		then
			whiptail --backtitle "SWAMID IDP Deployer" --title "Self signed certificate" --defaultno --yesno --clear -- \
				"Create a self signed certificate for HTTPS?\n\nThis is NOT recommended! Only for testing purposes" ${whipSize} 3>&1 1>&2 2>&3
			selfsignedNum=$?
			selfsigned="n"
			if [ "${selfsignedNum}" -eq 0 ]
			then
				selfsigned="y"
			fi
		else
			echo "Create a self signed certificate for https [ y | n ]"
			read selfsigned
			echo ""
		fi
	fi

	if [ "$sUI" = "y" ]
	then
		pass=$(whiptail --backtitle "SWAMID IDP Deployer" --title "IDP keystore password" --nocancel --passwordbox --clear -- \
			"Please input your IDP keystore password\n\nEmpty string generates new password." ${whipSize} 3>&1 1>&2 2>&3)
		httpspass=$(whiptail --backtitle "SWAMID IDP Deployer" --title "HTTPS Keystore password" --nocancel --passwordbox --clear -- \
			"Please input your Keystore password for HTTPS\n\nEmpty string generates new password." ${whipSize} 3>&1 1>&2 2>&3)
	else
		echo "IDP keystore password (empty string generates new password)"
		read pass
		echo ""
		echo "Keystore password for https (empty string generates new password)"
		read httpspass
		echo ""
	fi

# 	Confirmation
cat > ${Spath}/files/confirm.tx << EOM
Options passed to the installer:


Application server:        ${appserv}
Authentication type:       ${type}

Release to Google:         ${google}
Google domain name:        ${googleDom}

NTP server:                ${ntpserver}

LDAP server:               ${ldapserver}
LDAP Base DN:              ${ldapbasedn}
LDAP Bind DN:              ${ldapbinddn}
LDAP Subsearch:            ${subsearch}
norEduPersonNIN:           ${ninc}

IDP URL:                   ${idpurl}
CAS Login URL:             ${caslogurl}
CAS URL:                   ${casurl}

Cert org string:           ${certOrg}
Cert country string:       ${certC}
norEduOrgAcronym:          ${certAcro}
Country descriptor:        ${certLongC}

Usage data to SWAMID:      ${fticks}
EPTID support:             ${eptid}

Create self seigned cert:  ${selfsigned}
EOM

	cRet="1"
	if [ "$sUI" = "y" ]
	then
		whiptail --backtitle "SWAMID IDP Deployer" --title "Save config" --clear --yesno --defaultno -- "Do you want to save theese config values?\n\nIf you save theese values the current config file will be ovverwritten.\n NOTE: No passwords will be saved." ${whipSize} 3>&1 1>&2 2>&3
		cRet=$?
	else
		cat ${Spath}/files/confirm.tx
		/bin/echo -e  "Do you want to save theese config values?\n\nIf you save theese values the current config file will be ovverwritten.\n NOTE: No passwords will be saved."
		read cAns
		echo ""
		if [ "$cAns" = "y" ]
		then
			cRet="0"
		else
			cRet="1"
		fi
	fi
	if [ "${cRet}" -eq 0 ]
	then
		echo "appserv=\"${appserv}\""		> ${Spath}/config
		echo "type=\"${type}\""			>> ${Spath}/config
		echo "google=\"${google}\""		>> ${Spath}/config
		echo "googleDom=\"${googleDom}\""	>> ${Spath}/config
		echo "ntpserver=\"${ntpserver}\""	>> ${Spath}/config
		echo "ldapserver=\"${ldapserver}\""	>> ${Spath}/config
		echo "ldapbasedn=\"${ldapbasedn}\""	>> ${Spath}/config
		echo "ldapbinddn=\"${ldapbinddn}\""	>> ${Spath}/config
		echo "subsearch=\"${subsearch}\""	>> ${Spath}/config
		echo "idpurl=\"${idpurl}\""		>> ${Spath}/config
		echo "caslogurl=\"${caslogurl}\""	>> ${Spath}/config
		echo "casurl=\"${casurl}\""		>> ${Spath}/config
		echo "certOrg=\"${certOrg}\""		>> ${Spath}/config
		echo "certC=\"${certC}\""		>> ${Spath}/config
		echo "fticks=\"${fticks}\""		>> ${Spath}/config
		echo "eptid=\"${eptid}\""		>> ${Spath}/config
		echo "selfsigned=\"${selfsigned}\""	>> ${Spath}/config
		echo "ninc=\"${ninc}\""			>> ${Spath}/config
		echo "certAcro=\"${certAcro}\""		>> ${Spath}/config
		echo "certLongC=\"${certLongC}\""	>> ${Spath}/config
	fi
	cRet="1"
	if [ "$sUI" = "y" ]
	then
		whiptail --backtitle "SWAMID IDP Deployer" --title "Confirm" --scrolltext --clear --textbox ${Spath}/files/confirm.tx 20 75 3>&1 1>&2 2>&3
		whiptail --backtitle "SWAMID IDP Deployer" --title "Confirm" --clear --yesno --defaultno -- "Do you want to install this IDP with theese options?" ${whipSize} 3>&1 1>&2 2>&3
		cRet=$?
	else
		cat ${Spath}/files/confirm.tx
		echo "Do you want to install this IDP with theese options [ y | n ]?"
		read cAns
		echo ""
		if [ "$cAns" = "y" ]
		then
			cRet="0"
		fi
	fi
	rm ${Spath}/files/confirm.tx
	if [ "${cRet}" -ge 1 ]
	then
		exit
	fi
fi



/bin/echo -e "\n\n\n"
echo "Starting deployment!"
if [ "${upgrade}" -eq 1 ]
then
	echo "Previous installation found, performing upgrade."

	apt-get -qq install unzip wget
	cd /opt
	currentShib=`ls -l /opt/shibboleth-identityprovider |awk '{print $NF}'`
	currentVer=`echo ${currentShib} |awk -F\- '{print $NF}'`
	if [ "${currentVer}" = "${shibVer}" ]
	then
		mv ${currentShib} ${currentShib}.${ts}
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
		while [ -z "${idpurl}" ]
		do
			if [ "$sUI" = "y" ]
			then
				hostname=`hostname`
				hostname=`host -t A ${hostname} | awk '{print $1}'`
				idpurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "IDP URL" --nocancel --inputbox --clear -- \
					"Please input the URL to this IDP (https://idp.xxx.yy)." ${whipSize} "https://${hostname}" 3>&1 1>&2 2>&3)
			else
				echo "Specify IDP URL: (https://idp.xxx.yy)"
				read idpurl
				echo ""
			fi
		done

		while [ -z "${casurl}" ]
		do
			if [ "$sUI" = "y" ]
			then
				casurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "" --nocancel --inputbox --clear -- \
					"Please input the URL to yourCAS server (https://cas.xxx.yy/cas)." ${whipSize} "https://cas.${Dname}/cas" 3>&1 1>&2 2>&3)
			else
				echo "Specify CAS URL server: (https://cas.xxx.yy/cas)"
				read casurl
				echo ""
			fi
		done

		while [ -z "${caslogurl}" ]
		do
			if [ "$sUI" = "y" ]
			then
				caslogurl=$(whiptail --backtitle "SWAMID IDP Deployer" --title "" --nocancel --inputbox --clear -- \
					"Please input the Login URL to your CAS server (https://cas.xxx.yy/cas/login)." ${whipSize} "${casurl}/login" 3>&1 1>&2 2>&3)
			else
				echo "Specify CAS Login URL server: (https://cas.xxx.yy/cas/login)"
				read caslogurl
				echo ""
			fi
		done

		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/lib/
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/lib/
		mkdir /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib

		cat ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff.template \
			| perl -npe "s#IdPuRl#${idpurl}#" \
			| perl -npe "s#CaSuRl#${caslogurl}#" \
			| perl -npe "s#CaS2uRl#${casurl}#" \
			> ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
		files="`echo ${files}` ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff"

		patch /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/web.xml -i ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
	fi

	if [ -d "/opt/ndn-shib-fticks" ]
	then
		cp /opt/ndn-shib-fticks/target/*.jar /opt/shibboleth-identityprovider/lib
	else
		whiptail --backtitle "SWAMID IDP Deployer" --title "Send anonymous data" --yesno --clear -- \
			"Do you want to send anonymous usage data to SWAMID?\nThis is recommended." ${whipSize} 3>&1 1>&2 2>&3
		fticsNum=$?
		fticks="n"
		if [ "${fticsNum}" -eq 0 ]
		then
			fticks="y"
		fi

		if [ "${fticks}" != "n" ]
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

	if [ -d "/opt/mysql-connector-java-5.1.18/" ]
	then
		cp /opt/mysql-connector-java-5.1.18/mysql-connector-java-5.1.18-bin.jar /opt/shibboleth-identityprovider/lib/
	fi

	cd /opt
	tar zcf ${bupFile} shibboleth-idp

	cd /opt/shibboleth-identityprovider
	/bin/echo -e "\n\n\n\n"
	sh install.sh -Dinstall.config=no -Didp.home.input="/opt/shibboleth-idp"

else

	# install depends
	echo "Updating apt and installing generic dependancies"
	apt-get -qq update
	apt-get -qq install unzip default-jre apg wget

	# generate keystore pass
	if [ -z "${pass}" ]
	then
		pass=`${apgCmd}`
	fi
	if [ -z "${httpspass}" ]
	then
		httpspass=`${apgCmd}`
	fi
	if [ "${eptid}" != "n" -a -z "${mysqlPass}" ]
	then
		mysqlPass=`${apgCmd}`
		/bin/echo -e "Mysql root password generated\nPassword is '${mysqlPass}'" >> ${messages}
	fi

	idpfqdn=`echo ${idpurl} | awk -F\/ '{print $3}'`

	cd /opt
	# get depens if needed
	if [ "${appserv}" = "jboss" ]
	then
		if [ ! -f "${Spath}/files/jboss-as-distribution-6.1.0.Final.zip" ]
		then
			echo "Jboss not found, fetching from web"
			wget -q -O ${Spath}/files/jboss-as-distribution-6.1.0.Final.zip http://download.jboss.org/jbossas/6.1/jboss-as-distribution-6.1.0.Final.zip
		fi
		unzip -q ${Spath}/files/jboss-as-distribution-6.1.0.Final.zip
		chmod 755 jboss-6.1.0.Final
		ln -s /opt/jboss-6.1.0.Final /opt/jboss
	fi

	if [ "${appserv}" = "tomcat" ]
	then
		test=`dpkg -s tomcat6 > /dev/null 2>&1`
		isInstalled=$?
		if [ "${isInstalled}" -ne 0 ]
		then
			apt-get -qq install tomcat6
		fi
	fi

	if [ ! -f "${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip" ]
	then
		echo "Shibboleth not found, fetching from web"
		wget -q -O ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip http://www.shibboleth.net/downloads/identity-provider/${shibVer}/shibboleth-identityprovider-${shibVer}-bin.zip
	fi

	if [ "${type}" = "cas" ]
	then
		if [ ! -f "${Spath}/files/cas-client-3.2.1-release.zip" ]
		then
			echo "Cas-client not found, fetching from web"
			wget -q -O ${Spath}/files/cas-client-3.2.1-release.zip http://downloads.jasig.org/cas-clients/cas-client-3.2.1-release.zip
		fi
		unzip -q ${Spath}/files/cas-client-3.2.1-release.zip
	fi

	# unzip all files
	echo "Unzipping dependancies"

	unzip -q ${Spath}/files/shibboleth-identityprovider-${shibVer}-bin.zip
	chmod -R 755 /opt/shibboleth-identityprovider-${shibVer}
	ln -s shibboleth-identityprovider-${shibVer} shibboleth-identityprovider

	if [ "${type}" = "cas" ]
	then
	# copy cas depends into shibboleth
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/lib/
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/lib/
		mkdir /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/cas-client-core-3.2.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib
		cp /opt/cas-client-3.2.1/modules/commons-logging-1.1.jar /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/lib

		cat ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff.template \
			| perl -npe "s#IdPuRl#${idpurl}#" \
			| perl -npe "s#CaSuRl#${caslogurl}#" \
			| perl -npe "s#CaS2uRl#${casurl}#" \
			> ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
		files="`echo ${files}` ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff"

		patch /opt/shibboleth-identityprovider/src/main/webapp/WEB-INF/web.xml -i ${Spath}/${prep}/shibboleth-identityprovider-web.xml.diff
	fi

	if [ "${fticks}" != "n" ]
	then
		echo "Installing ndn-shib-fticks"
		apt-get install git maven2
		cd /opt
		git clone git://github.com/leifj/ndn-shib-fticks.git
		cd ndn-shib-fticks
		mvn
		cp /opt/ndn-shib-fticks/target/*.jar /opt/shibboleth-identityprovider/lib
	fi

	if [ "${eptid}" != "n" ]
	then
		test=`dpkg -s mysql-server > /dev/null 2>&1`
		isInstalled=$?
		if [ "${isInstalled}" -ne 0 ]
		then
			export DEBIAN_FRONTEND=noninteractive
			apt-get -qq -y install mysql-server
			
			# set mysql root password
			tfile=`mktemp`
			if [ ! -f "$tfile" ]; then
				return 1
			fi
			cat << EOF > $tfile
USE mysql;
UPDATE user SET password=PASSWORD("${mysqlPass}") WHERE user='root';
FLUSH PRIVILEGES;
EOF

			mysql --no-defaults -u root -h localhost <$tfile >/dev/null
			retval=$?
			rm -f $tfile
			if [ "${retval}" -ne 0 ]
			then
				/bin/echo -e "\n\n\nAn error has occurred in the configuration of the MySQL installation."
				echo "Please correct the MySQL installation and make sure a root password is set and it is possible to log in using the 'mysql' command."
				echo "When MySQL is working, re-run this script."
				cleanBadInstall
				exit 1
			fi
		fi

		wget -O ${Spath}/files/mysql-connector-java-5.1.18.tar.gz http://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.18.tar.gz/from/http://ftp.sunet.se/pub/unix/databases/relational/mysql/
		tar zxf ${Spath}/files/mysql-connector-java-5.1.18.tar.gz
		cp /opt/mysql-connector-java-5.1.18/mysql-connector-java-5.1.18-bin.jar /opt/shibboleth-identityprovider/lib/

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
	files="`echo ${files}` ${Spath}/xml/server.xml"

	ldapServerStr=""
	for i in `echo ${ldapserver}`
	do
		ldapServerStr="`echo ${ldapServerStr}` ldap://${i}"
	done
	ldapServerStr=`echo ${ldapServerStr} | perl -npe 's/^\s+//'`
	cat ${Spath}/xml/attribute-resolver.xml.diff.template \
		| perl -npe "s#LdApUrI#${ldapServerStr}#" \
		| perl -npe "s/LdApBaSeDn/${ldapbasedn}/" \
		| perl -npe "s/LdApCrEdS/${ldapbinddn}/" \
		| perl -npe "s/LdApPaSsWoRd/${ldappass}/" \
		| perl -npe "s/NiNcRePlAcE/${ninc}/" \
		| perl -npe "s/CeRtAcRoNyM/${certAcro}/" \
		| perl -npe "s/CeRtOrG/${certOrg}/" \
		| perl -npe "s/CeRtC/${certC}/" \
		| perl -npe "s/CeRtLoNgC/${certLongC}/" \
		> ${Spath}/xml/attribute-resolver.xml.diff
	files="`echo ${files}` ${Spath}/xml/attribute-resolver.xml.diff"

	# Get TCS CA chain, import ca-certs into java and create https cert request
	mkdir -p ${certpath}
	cd ${certpath}
	echo "Fetching TCS CA chain from web"
	wget -q -O ${certpath}/server.chain ${certificateChain}
	if [ ! -s "${certpath}/server.chain" ]
	then
		echo "Can not get the certificate chain, aborting install."
		cleanBadInstall
		exit 1
	fi

	echo "Installing TCS CA chain in java cacert keystore"
	cnt=1
	for i in `cat ${certpath}server.chain | perl -npe 's/\ /\*\*\*/g'`
	do
		n=`echo ${i} | perl -npe 's/\*\*\*/\ /g'`
		echo ${n} >> ${certpath}${cnt}.root
		ltest=`echo ${n} | grep "END CERTIFICATE"`
		if [ ! -z "${ltest}" ]
		then
			cnt=`expr ${cnt} + 1`
		fi
	done
	ccnt=1
	while [ ${ccnt} -lt ${cnt} ]
	do
		subject=`openssl x509 -noout -in ${certpath}${ccnt}.root -subject | awk -F/ '{print $NF}' |cut -d= -f2`
		test=`keytool -list -keystore ${javaCAcerts} -storepass changeit -alias "${subject}"`
		res=$?
		if [ "${res}" -ne 0 ]
		then
			keytool -import -trustcacerts -alias "${subject}" -file ${certpath}${ccnt}.root -keystore ${javaCAcerts} -storepass changeit 2>/dev/null
		fi
		files="`echo ${files}` ${certpath}${ccnt}.root"
		ccnt=`expr ${ccnt} + 1`
	done

	if [ ! -s "${httpsP12}" ]
	then
		echo "Generating SSL key and certificate request"
		openssl genrsa -out ${certpath}server.key 2048 2>/dev/null
		openssl req -new -key ${certpath}server.key -out ${certREQ} -config ${Spath}/files/openssl.cnf -subj "/CN=${idpfqdn}/O=${certOrg}/C=${certC}"
	fi
	if [ "${selfsigned}" = "n" ]
	then
		echo "Put the certificate from TCS in the file: ${certpath}server.crt" >> ${messages}
		echo "Run: openssl pkcs12 -export -in ${certpath}server.crt -inkey ${certpath}server.key -out ${httpsP12} -name tomcat -passout pass:${httpspass}" >> ${messages}
	else
		openssl x509 -req -days 365 -in ${certREQ} -signkey ${certpath}server.key -out ${certpath}server.crt
		openssl pkcs12 -export -in ${certpath}server.crt -inkey ${certpath}server.key -out ${httpsP12} -name tomcat -passout pass:${httpspass}
	fi

	# application server specific
	if [ "${appserv}" = "jboss" ]
	then
		if [ "${type}" = "ldap" ]
		then
			ldapServerStr=""
			for i in `echo ${ldapserver}`
			do
				ldapServerStr="`echo ${ldapServerStr}` ldap://${i}"
			done
			ldapServerStr=`echo ${ldapServerStr} | perl -npe 's/^\s+//'`

			cat ${Spath}/${prep}/login-config.xml.diff.template \
				| perl -npe "s#LdApUrI#${ldapServerStr}#" \
				| perl -npe "s/LdApBaSeDn/${ldapbasedn}/" \
				| perl -npe "s/SuBsEaRcH/${subsearch}/" \
				> ${Spath}/${prep}/login-config.xml.diff
			files="`echo ${files}` ${Spath}/${prep}/login-config.xml.diff"
			patch /opt/jboss/server/default/conf/login-config.xml -i ${Spath}/${prep}/login-config.xml.diff
		fi

		ln -s /opt/shibboleth-idp/war/idp.war /opt/jboss/server/default/deploy/

		cp ${Spath}/xml/server.xml /opt/jboss/server/default/deploy/jbossweb.sar/server.xml
		chmod o-rwx /opt/jboss/server/default/deploy/jbossweb.sar/server.xml

		echo "Add basic jboss init script to start on boot"
		cp ${Spath}/files/jboss.init /etc/init.d/jboss
		update-rc.d jboss defaults
	fi

	if [ "${appserv}" = "tomcat" ]
	then
		if [ "${type}" = "ldap" ]
		then
			ldapServerStr=""
			for i in `echo ${ldapserver}`
			do
				ldapServerStr="`echo ${ldapServerStr}` ldap://${i}:389"
			done
			ldapServerStr="`echo ${ldapServerStr} | perl -npe 's/^\s+//'`"

			cat ${Spath}/${prep}/login.conf.diff.template \
				| perl -npe "s#LdApUrI#${ldapServerStr}#" \
				| perl -npe "s/LdApBaSeDn/${ldapbasedn}/" \
				| perl -npe "s/SuBsEaRcH/${subsearch}/" \
				> ${Spath}/${prep}/login.conf.diff
			files="`echo ${files}` ${Spath}/${prep}/login.conf.diff"
			patch /opt/shibboleth-idp/conf/login.config -i ${Spath}/${prep}/login.conf.diff
		fi

		cp ${Spath}/xml/tomcat.idp.xml /var/lib/tomcat6/conf/Catalina/localhost/idp.xml

		if [ ! -d "/usr/share/tomcat6/endorsed" ]
		then
			mkdir /usr/share/tomcat6/endorsed
		fi
		for i in `ls /opt/shibboleth-identityprovider/endorsed/`
		do
			if [ ! -s "/usr/share/tomcat6/endorsed/${i}" ]
			then
				cp /opt/shibboleth-identityprovider/endorsed/${i} /usr/share/tomcat6/endorsed
			fi
		done

		. /etc/default/tomcat6
		if [ -z "`echo ${JAVA_OPTS} | grep '/usr/share/tomcat6/endorsed'`" ]
		then
			JAVA_OPTS="${JAVA_OPTS} -Djava.endorsed.dirs=/usr/share/tomcat6/endorsed"
			echo "JAVA_OPTS=\"${JAVA_OPTS}\"" >> /etc/default/tomcat6
		else
			echo "JAVA_OPTS for tomcat already configured" >> ${messages}
		fi
		if [ "${AUTHBIND}" != "yes" ]
		then
			echo "AUTHBIND=yes" >> /etc/default/tomcat6
		else
			echo "AUTHBIND for tomcat already configured" >> ${messages}
		fi

		wget -q -O /usr/share/tomcat6/lib/tomcat6-dta-ssl-1.0.0.jar ${tomcatDepend}
		if [ ! -s "/usr/share/tomcat6/lib/tomcat6-dta-ssl-1.0.0.jar" ]
		then
			echo "Can not get tomcat dependancy, aborting install."
			cleanBadInstall
			exit 1
		fi

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

	wget -O ${idpPath}/credentials/md-signer.crt http://md.swamid.se/md/md-signer.crt
	cFinger=`openssl x509 -noout -fingerprint -sha1 -in ${idpPath}/credentials/md-signer.crt | cut -d\= -f2`
	cCnt=1
	while [ "${cFinger}" != "${mdSignerFinger}" -a "${cCnt}" -le 10 ]
	do
		wget -O ${idpPath}/credentials/md-signer.crt http://md.swamid.se/md/md-signer.crt
		cFinger=`openssl x509 -noout -fingerprint -sha1 -in ${idpPath}/credentials/md-signer.crt | cut -d\= -f2`
		cCnt=`expr ${cCnt} + 1`
	done
	if [ "${cFinger}" != "${mdSignerFinger}" ]
	then
		 echo "Fingerprint error on md-signer.crt!\nGet ther certificate from http://md.swamid.se/md/md-signer.crt and verify it, then place it in the file: ${idpPath}/credentials/md-signer.crt" >> ${messages}
	fi

	# patch shibboleth config files
	echo "Patching config files"
	patch /opt/shibboleth-idp/conf/handler.xml -i ${Spath}/${prep}/handler.xml.diff
	patch /opt/shibboleth-idp/conf/relying-party.xml -i ${Spath}/xml/relying-party.xml.diff
	patch /opt/shibboleth-idp/conf/attribute-filter.xml -i ${Spath}/xml/attribute-filter.xml.diff
	patch /opt/shibboleth-idp/conf/attribute-resolver.xml -i ${Spath}/xml/attribute-resolver.xml.diff

	if [ "${google}" != "n" ]
	then
		patch /opt/shibboleth-idp/conf/attribute-filter.xml -i ${Spath}/xml/google-filter.diff
		cat ${Spath}/xml/google-relay.diff.template | perl -npe "s/IdPfQdN/${idpfqdn}/" > ${Spath}/xml/google-relay.diff
		files="`echo ${files}` ${Spath}/xml/google-relay.diff"
		patch /opt/shibboleth-idp/conf/relying-party.xml -i ${Spath}/xml/google-relay.diff
		cat ${Spath}/xml/google.xml | perl -npe "s/GoOgLeDoMaIn/${googleDom}/" > /opt/shibboleth-idp/metadata/google.xml
	fi

	if [ "${fticks}" != "n" ]
	then
		patch /opt/shibboleth-idp/conf/logging.xml -i ${Spath}/xml/fticks.diff
		touch /opt/shibboleth-idp/conf/fticks-key.txt
		if [ "${appserv}" = "tomcat" ]
		then
			chown tomcat6 /opt/shibboleth-idp/conf/fticks-key.txt
		fi
	fi

	if [ "${eptid}" != "n" ]
	then
		epass=`${apgCmd}`
		esalt=`openssl rand -base64 36 2>/dev/null`
		cat ${Spath}/xml/eptid.sql.template | perl -npe "s#SqLpAsSwOrD#${epass}#" > ${Spath}/xml/eptid.sql
		files="`echo ${files}` ${Spath}/xml/eptid.sql"

		echo "Create MySQL database and shibboleth user."
		mysql -uroot -p"${mysqlPass}" < ${Spath}/xml/eptid.sql

		cat ${Spath}/xml/eptid-AR.diff.template \
			| perl -npe "s#SqLpAsSwOrD#${epass}#" \
			| perl -npe "s#Large_Random_Salt_Value#${esalt}#" \
			> ${Spath}/xml/eptid-AR.diff
		files="`echo ${files}` ${Spath}/xml/eptid-AR.diff"

		patch /opt/shibboleth-idp/conf/attribute-resolver.xml -i ${Spath}/xml/eptid-AR.diff
		patch /opt/shibboleth-idp/conf/attribute-filter.xml -i ${Spath}/xml/eptid-AF.diff
	fi

	# add crontab entry for ntpdate
	test=`crontab -l 2>/dev/null |grep "${ntpserver}" |grep ntpdate`
	if [ -z "${test}" ]
	then
		echo "Adding crontab entry for ntpdate"
		CRONTAB=`crontab -l 2>/dev/null | perl -npe 's/^$//'`
		if [ ! -z "${CRONTAB}" ]
		then
			CRONTAB="${CRONTAB}\n"
		fi
		/bin/echo -e "${CRONTAB}*/5 *  *   *   *     /usr/sbin/ntpdate ${ntpserver} > /dev/null 2>&1" | crontab
	fi
fi

if [ "${cleanUp}" -eq 1 ]
then
	# remove configs with templates
	for i in ${files}
	do
		rm ${i}
	done
else
	echo "Files created by script"
	for i in ${files}
	do
		echo ${i}
	done
fi

/bin/echo -e "\n\n\n"

if [ "${upgrade}" -eq 1 ]
then
	echo "Upgrade done."
	echo "A backup of the previos shibboleth installation is saved in: ${bupFile}"
else
	if [ "${selfsigned}" = "n" ]
	then
		cat ${certREQ}
		echo "Here is the certificate request, go get at cert!"
		echo "Or replace the cert files in ${certpath}"
		/bin/echo -e "\n\nNOTE!!! the keystore for https is a PKCS12 store\n\n"
	fi
	echo ""
	echo "Register at testshib.org and register idp, and run a logon test."
	echo "Certificate for idp metadata is in the file: /opt/shibboleth-idp/credentials/idp.crt"
fi

if [ "${type}" = "ldap" ]
then
	/bin/echo -e "\n\n"
	echo "Read this to customize the logon page: https://wiki.shibboleth.net/confluence/display/SHIB2/IdPAuthUserPassLoginPage"
fi

if [ -s "${messages}" ]
then
	cat ${messages}
	rm ${messages}
fi
